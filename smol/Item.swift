//
//  Item.swift
//  smol
//
//  Created by Alin Sfirschi on 08/01/26.
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
