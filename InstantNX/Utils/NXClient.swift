//
//  NXClient.swift
//  InstantNX
//
//  Created by devonly on 2024/10/13.
//  Copyright © 2024 Magi, Corporation. All rights reserved.
//

import Alamofire
import AVFoundation
import CodeScanner
import CoreLocation
import Foundation
import Network
import NetworkExtension
import QuantumLeap
import SwiftUI
import SystemConfiguration.CaptiveNetwork
import UIKit

final class NXClient: ObservableObject, RequestRetrier, RequestInterceptor, @unchecked Sendable {
    // MARK: Internal

    @Published var contents: [ContentItem] = []
    /// 完了時にダイアログを表示
    @Published var isCompleted: Bool = false
    @Published private(set) var status: NXStatus = .WAITING
    @Published private(set) var progress: Double = 0.0
    @Published var autosave: Bool = true
    @Published var shouldShowOpenPhotoLibraryDialog: Bool = true

    var isConnecting: Binding<Bool> {
        .constant(status != .WAITING)
    }

    func retry(_ request: Alamofire.Request, for _: Alamofire.Session, dueTo error: any Error, completion: @escaping (Alamofire.RetryResult) -> Void) {
        if let error = error.asAFError,
           case let .responseValidationFailed(reason) = error,
           case let .unacceptableStatusCode(code) = reason,
           code == 404,
           request.retryCount < 5
        {
            Logger.error("Request failed with status code: \(code). Retrying...")
            completion(.retryWithDelay(1))
        }
        Logger.error("Request failed with error: \(error.localizedDescription). Not retrying.")
        completion(.doNotRetry)
    }

    // MARK: Private

    private let decoder: JSONDecoder = .init()
    private let session: Session = .default
    private let url: URL = .init(string: "http://192.168.0.1/data.json")!
    private var configuration: NEHotspotConfiguration = .init()
    private let monitor: NWPathMonitor = .init()
    private let queue: DispatchQueue = .global(qos: .background)
    private let manager: CLLocationManager = .init()

    init() {
        manager.requestWhenInUseAuthorization()
        monitor.start(queue: queue)
        monitor.pathUpdateHandler = { [weak self] path in
            Logger.debug(path)
        }
    }

    // http://192.168.0.1/img/2024100609504500-4CE9651EE88A979D41F24CE8D6EA1C23.jpg
    // http://192.168.0.1/img/2024040620202600-4CE9651EE88A979D41F24CE8D6EA1C23.mp4
    /// 保存する
    @MainActor
    func save() async throws {
        let response = try await session.request(url, method: .get, interceptor: self)
            .validate()
            .serializingDecodable(NXScanResult.self, decoder: decoder)
            .value
        status = .DOWNLOADING
        switch response.fileType {
            case .photo:
                let images: [(UIImage, URL)] = try await withThrowingTaskGroup(of: (UIImage, URL).self, body: { task in
                    for content in response.contents {
                        task.addTask(priority: .background, operation: { [self] in
                            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(content.lastPathComponent)
                            let destination: DownloadRequest.Destination = { _, _ in
                                (fileURL, [.removePreviousFile, .createIntermediateDirectories])
                            }
                            Logger.debug("Downloading content: \(content)")
                            return try await (.init(data: session.download(content, to: destination)
                                    .downloadProgress(closure: { [weak self] progress in
                                        self?.progress = progress.fractionCompleted
                                    })
                                    .serializingData(automaticallyCancelling: true)
                                    .value)!, fileURL)
                        })
                    }
                    return try await task.reduce(into: [(UIImage, URL)]()) { results, result in
                        results.append(result)
                    }
                })
                contents = images.map { ContentItem($0.1, type: .photo, image: $0.0) }
                if autosave {
                    for image in images {
                        UIImageWriteToSavedPhotosAlbum(image.0, nil, nil, nil)
                    }
                }
            case .movie:
                let movies: [(UIImage, URL)] = try await withThrowingTaskGroup(of: (UIImage, URL).self, body: { task in
                    for content in response.contents {
                        task.addTask(priority: .background, operation: { [self] in
                            let destination: DownloadRequest.Destination = { _, _ in
                                let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(content.lastPathComponent)
                                return (fileURL, [.removePreviousFile, .createIntermediateDirectories])
                            }
                            Logger.debug("Downloading content: \(content)")
                            let asset: AVURLAsset = .init(url: content)
                            let generator: AVAssetImageGenerator = .init(asset: asset)
                            let image: CGImage = try await generator.image(at: .init(value: 0, timescale: .max)).image
                            return try await (UIImage(cgImage: image), session.download(content, to: destination)
                                .downloadProgress(closure: { [weak self] progress in
                                    self?.progress = progress.fractionCompleted
                                })
                                .serializingDownloadedFileURL(automaticallyCancelling: true)
                                .value)
                        })
                    }
                    return try await task.reduce(into: [(UIImage, URL)]()) { results, fileURL in
                        results.append(fileURL)
                    }
                })
                contents = movies.map { ContentItem($0.1, type: .movie, image: $0.0) }
                if autosave {
                    for movie in movies {
                        UISaveVideoAtPathToSavedPhotosAlbum(movie.1.path, nil, nil, nil)
                    }
                }
        }
        if shouldShowOpenPhotoLibraryDialog {
            isCompleted = true
        }
    }

    @MainActor
    func connect(_ result: ScanResult) async throws {
        let capture: [String] = result.string.capture(pattern: #"WIFI:S:(switch_[\d]{10}I);T:WPA;P:([\w\d]{8});;"#, group: [1, 2])
        if capture.count != 2 {
            return
        }
        configuration = .init(ssid: capture[0], passphrase: capture[1], isWEP: false)
        configuration.joinOnce = true
        defer {
            status = .WAITING
        }
        status = .PREPARING
        try await NEHotspotConfigurationManager.shared.apply(configuration)
        try await wait(ssid: configuration.ssid)
        status = .CONNECTING
        try await save()
    }

    @MainActor
    func disconnect() async throws {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: configuration.ssid)
    }

    private func wait(ssid: String, timeout: TimeInterval = 10) async throws {
        let startTime: Date = .now
        try await withCheckedThrowingContinuation { continuation in
            Task(priority: .background, operation: {
                while true {
                    if let current: NEHotspotNetwork = await NEHotspotNetwork.fetchCurrent() {
                        if current.ssid == ssid {
                            continuation.resume()
                            return
                        }
                    } else {
                        try? await Task.sleep(for: .milliseconds(5_000))
                        continuation.resume()
                        return
                    }
                    if Date().timeIntervalSince(startTime) > timeout {
                        continuation.resume(throwing: URLError(.timedOut))
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            })
        }
    }
}

enum FileType: String, Codable, Hashable {
    case photo
    case movie
}

struct ContentItem: Hashable {
    let type: FileType
    let url: URL
    let image: UIImage
    var isSelected: Bool

    init(_ url: URL, type: FileType, image: UIImage) {
        self.url = url
        isSelected = true
        self.type = type
        self.image = image
    }
}

struct NXScanResult: Codable {
    let photoHelpMes: String
    let downloadMes: String
    let fileType: FileType
    let movieHelpMes: String
    let consoleName: String
    let fileNames: [String]

    var contents: [URL] {
        fileNames.compactMap { .init(string: "http://192.168.0.1/img/\($0)") }
    }

    enum CodingKeys: String, CodingKey {
        case photoHelpMes = "PhotoHelpMes"
        case downloadMes = "DownloadMes"
        case fileType = "FileType"
        case movieHelpMes = "MovieHelpMes"
        case consoleName = "ConsoleName"
        case fileNames = "FileNames"
    }
}
