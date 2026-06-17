//
//  Item.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
