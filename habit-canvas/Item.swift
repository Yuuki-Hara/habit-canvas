//
//  Item.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
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
