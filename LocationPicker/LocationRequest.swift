//
//  LocationRequest.swift
//  LocationPicker
//
//  Created by Alexander Polovinka on 10/5/18.
//  Copyright © 2018 almassapargali. All rights reserved.
//

import Foundation
import CoreLocation

public class LocationRequest  {
    let address: String?
    let location: CLLocation?

    public init(address: String? = nil, location: CLLocation?) {
        self.address = address
        self.location = location
    }
}
