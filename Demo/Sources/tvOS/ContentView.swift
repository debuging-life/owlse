//
//  ContentView.swift
//  Owlse tvOS
//
//  Created by Alexander Grebenyuk on 07.03.2021.
//  Copyright © 2021 kean. All rights reserved.
//

import SwiftUI
import OwlseUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            ConsoleView(store: .demo)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
