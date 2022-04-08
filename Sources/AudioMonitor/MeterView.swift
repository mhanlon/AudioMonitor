//
//  File.swift
//  AudioMonitor
//
//  Created by Matthew Hanlon on 4/7/22.
//

import SwiftUI

struct MeterView: View {
    var volume: Double = 0.0
    var stepByValue: Double = 0.075
    var volumes: [Double] {
        Array(stride(from: 0.0, to: 1.0, by: stepByValue))
    }
    
    var body: some View {
        HStack {
            ForEach(volumes, id: \.self) { value in 
                RoundedRectangle(cornerRadius: 5)
                    .foregroundColor(value < volume ? .green : .red)
                    .frame(minWidth: 10, maxHeight: 30)
            }
        }
        .padding()
    }
    
}
