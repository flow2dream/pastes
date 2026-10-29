//
//  Item.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import Foundation

struct ClipboardItem: Identifiable, Equatable {
    var id: UUID
    var content: String
    var imageData: Data?
    var rtfData: Data?
    var timestamp: Date
    var isPinned: Bool
    var isImage: Bool

    init(id: UUID = UUID(), content: String, imageData: Data? = nil, rtfData: Data? = nil, timestamp: Date = Date(), isPinned: Bool = false) {
        self.id = id
        self.content = content
        self.imageData = imageData
        self.rtfData = rtfData
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.isImage = imageData != nil
    }
}
