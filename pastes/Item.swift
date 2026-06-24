//
//  Item.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import Foundation
import SwiftData

@Model
final class ClipboardItem {
    var content: String
    var imageData: Data?
    var rtfData: Data?
    var timestamp: Date
    var isPinned: Bool
    var isImage: Bool = false

    init(content: String, imageData: Data? = nil, rtfData: Data? = nil, timestamp: Date = Date(), isPinned: Bool = false) {
        self.content = content
        self.imageData = imageData
        self.rtfData = rtfData
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.isImage = imageData != nil
    }
}
