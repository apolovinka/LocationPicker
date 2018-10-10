//
//  LocationPickerViewController.swift
//  LocationPicker
//
//  Created by Almas Sapargali on 7/29/15.
//  Copyright (c) 2015 almassapargali. All rights reserved.
//

import UIKit
import MapKit
import CoreLocation

open class LocationPickerViewController: UIViewController {
	struct CurrentLocationListener {
		let once: Bool
		let action: (CLLocation) -> ()
	}
	
	public var completion: ((Location?) -> ())?
	
	// region distance to be used for creation region when user selects place from search results
	public var resultRegionDistance: CLLocationDistance = 600
	
	/// default: true
	public var showCurrentLocationButton = true
	
	/// default: true
	public var showCurrentLocationInitially = true

    /// default: false
    /// Select current location only if `location` property is nil.
    public var selectCurrentLocationInitially = false
	
	/// see `region` property of `MKLocalSearchRequest`
	/// default: false
	public var useCurrentLocationAsHint = false
	
	/// default: "Search or enter an address"
	public var searchBarPlaceholder = "Search or enter an address"
	
	/// default: "Search History"
	public var searchHistoryLabel = "Search History"
    
    /// default: "Select"
    public var selectButtonTitle = "Select"

    public var initialLocationRequest: LocationRequest? = nil

    public var pinImage: UIImage?
	
	lazy public var currentLocationButtonBackground: UIColor = {
		if let navigationBar = self.navigationController?.navigationBar,
			let barTintColor = navigationBar.barTintColor {
				return barTintColor
		} else { return .white }
	}()

    /// default: .Minimal
    public var searchBarStyle: UISearchBarStyle = .minimal

	/// default: .Default
	public var statusBarStyle: UIStatusBarStyle = .default

    public var shouldShowAnnotations: Bool = false
    public var shouldHideUserLocation: Bool = true
    public var shouldShowConfirmButton: Bool = true

	public var mapType: MKMapType = .hybrid {
		didSet {
			if isViewLoaded {
				mapView.mapType = mapType
			}
		}
	}
	
	public var location: Location? {
		didSet {
			if isViewLoaded {
				searchBar.text = location.flatMap({ $0.title }) ?? ""
				updateAnnotation()
			}
		}
	}

    public var locationButton: UIButton?

    public var confirmButton: UIButton?

    public var confirmButtonTitle = "Confirm map pin"

	static let SearchTermKey = "SearchTermKey"
	
	let historyManager = SearchHistoryManager()
	let locationManager = CLLocationManager()
	let geocoder = CLGeocoder()
	var localSearch: MKLocalSearch?
	var searchTimer: Timer?
	
	var currentLocationListeners: [CurrentLocationListener] = []
    private var mapViewContraintBottom: NSLayoutConstraint!
	
	var mapView: MKMapView!
    var pinImageView: UIImageView?
    var confirmButtonContainerView: UIView?

    private var mapChangedFromUserInteraction = false
	
	lazy var results: LocationSearchResultsViewController = {
		let results = LocationSearchResultsViewController()
		results.onSelectLocation = { [weak self] in self?.selectedLocation($0) }
		results.searchHistoryLabel = self.searchHistoryLabel
		return results
	}()
	
	lazy var searchController: UISearchController = {
		let search = UISearchController(searchResultsController: self.results)
		search.searchResultsUpdater = self
		search.hidesNavigationBarDuringPresentation = false
		return search
	}()
	
	public lazy var searchBar: UISearchBar = {
		let searchBar = self.searchController.searchBar
		searchBar.searchBarStyle = self.searchBarStyle
		searchBar.placeholder = self.searchBarPlaceholder
		return searchBar
	}()
	
	deinit {
		searchTimer?.invalidate()
		localSearch?.cancel()
		geocoder.cancelGeocode()
        // http://stackoverflow.com/questions/32675001/uisearchcontroller-warning-attempting-to-load-the-view-of-a-view-controller/
        let _ = searchController.view
	}
	
	open override func viewDidLoad() {
		super.viewDidLoad()

        self.extendedLayoutIncludesOpaqueBars = true

        self.setupMapView()

        if self.shouldShowConfirmButton {
            self.setupConfirmButton()
        }

        self.showCenterPinIfNeeds()
		
		locationManager.delegate = self
		mapView.delegate = self
		searchBar.delegate = self
		
		// gesture recognizer for adding by tap
        let locationSelectGesture = UILongPressGestureRecognizer(
            target: self, action: #selector(addLocation(_:)))
        locationSelectGesture.delegate = self
		mapView.addGestureRecognizer(locationSelectGesture)

        let panRegognizer = UIPanGestureRecognizer(target: self, action: #selector(didDragViewGestureRecognizerAction(sender:)))
        panRegognizer.delegate = self
        self.mapView.addGestureRecognizer(panRegognizer)

		// search
        if #available(iOS 11.0, *) {
            navigationItem.searchController = searchController
        } else {
            navigationItem.titleView = searchBar
        }
		definesPresentationContext = true
		
		// user location
		mapView.userTrackingMode = .none
		mapView.showsUserLocation = showCurrentLocationInitially || showCurrentLocationButton
		
		if useCurrentLocationAsHint {
			getCurrentLocation()
		}

	}

    func setupMapView() {

        mapView = MKMapView(frame: UIScreen.main.bounds)
        mapView.mapType = mapType
        mapView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(mapView)

        if #available(iOS 9.0, *) {
            mapView.topAnchor.constraint(equalTo: self.view.topAnchor).isActive = true
            self.mapViewContraintBottom = mapView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
            self.mapViewContraintBottom.isActive = true
            mapView.leftAnchor.constraint(equalTo: self.view.leftAnchor).isActive = true
            mapView.rightAnchor.constraint(equalTo: self.view.rightAnchor).isActive = true
        }

        if showCurrentLocationButton {
            let button = UIButton(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
            button.backgroundColor = currentLocationButtonBackground
            button.layer.masksToBounds = true
            button.layer.cornerRadius = 16
            let bundle = Bundle(for: LocationPickerViewController.self)
            button.setImage(UIImage(named: "geolocation", in: bundle, compatibleWith: nil), for: UIControlState())
            button.addTarget(self, action: #selector(LocationPickerViewController.currentLocationPressed),
                             for: .touchUpInside)
            view.addSubview(button)
            locationButton = button
        }
    }

	open override var preferredStatusBarStyle : UIStatusBarStyle {
		return statusBarStyle
	}
	
	var presentedInitialLocation = false
	
	open override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		if let button = locationButton {
			button.frame.origin = CGPoint(
				x: 16,
				y: 16 + self.topPadding()
			)
		}
		
		// setting initial location here since viewWillAppear is too early, and viewDidAppear is too late
		if !presentedInitialLocation {
			setInitialLocation()
			presentedInitialLocation = true
		}
	}

    func topPadding() -> CGFloat {
        var searchBarHeight: CGFloat = 0
        if #available(iOS 11.0, *) {
            searchBarHeight = self.searchBar.frame.height
        }
        return (self.navigationController?.navigationBar.frame.size.height ?? 0)
            + searchBarHeight
            + UIApplication.shared.statusBarFrame.height

    }
	
	func setInitialLocation() {
		if let location = location {
			// present initial location if any
			self.location = location
			showCoordinates(location.coordinate, animated: false)
            self.setConfirmButton(enabled: false)
            return
        } else if let locationRequest = self.initialLocationRequest {
            if let location = locationRequest.location {
                self.showCoordinates(location.coordinate, animated: false)
                self.setConfirmButton(enabled: false)
            }
        } else if showCurrentLocationInitially || selectCurrentLocationInitially {
            if selectCurrentLocationInitially {
                let listener = CurrentLocationListener(once: true) { [weak self] location in
                    if self?.location == nil { // user hasn't selected location still
                        self?.selectLocation(location: location)
                    }
                }
                currentLocationListeners.append(listener)
            }
			showCurrentLocation(false)
		}
//        self.searchController.isActive = true
//        self.searchBar.text = "Ukraine, Dnipro"
//        self.search(for: "Ukraine, Dnipro")
	}

    func setConfirmButton(enabled: Bool) {
        self.confirmButton?.isEnabled = enabled
    }

    func showCenterPinIfNeeds() {
        guard let pinImage = self.pinImage else {
            return
        }
        let imageView = UIImageView(image: pinImage)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(imageView)
        self.pinImageView = imageView
        self.layoutPinView()
    }

    func layoutPinView() {
        guard let pinImageView = self.pinImageView else {
            return
        }
        if #available(iOS 9.0, *) {
            pinImageView.centerXAnchor.constraint(equalTo: self.mapView.centerXAnchor).isActive = true
            let constraint = pinImageView.centerYAnchor.constraint(equalTo: self.mapView.centerYAnchor)
            var searchBarHeight: CGFloat = 0
            if #available(iOS 11.0, *) {
                searchBarHeight = self.searchBar.frame.height
            }
            constraint.constant += ((self.navigationController?.navigationBar.frame.size.height ?? 0) + searchBarHeight + UIApplication.shared.statusBarFrame.height)/2 - pinImageView.frame.height/2
            constraint.isActive = true
        }

    }

    func setupConfirmButton () {
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(contentView)
        self.confirmButtonContainerView = contentView
        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.7)
        var safeAreaInsets: UIEdgeInsets?
        if #available(iOS 11.0, *) {
            safeAreaInsets = UIApplication.shared.keyWindow?.safeAreaInsets
        }
        if #available(iOS 9.0, *) {
            contentView.leftAnchor.constraint(equalTo: self.view.leftAnchor).isActive = true
            contentView.rightAnchor.constraint(equalTo: self.view.rightAnchor).isActive = true
            contentView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor).isActive = true
            let height: CGFloat = 60
            let heightConstraint = contentView.heightAnchor.constraint(equalToConstant: height)
            if #available(iOS 11.0, *) {
                heightConstraint.constant += safeAreaInsets?.bottom ?? 0.0
            }
            heightConstraint.isActive = true
            self.mapViewContraintBottom.isActive = false
            self.mapViewContraintBottom = self.mapView.bottomAnchor.constraint(equalTo: contentView.topAnchor)
            self.mapViewContraintBottom.isActive = true
        }

        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        button.addTarget(self, action: #selector(self.confirmButtonAction(sender:)), for: .touchUpInside)
        button.setTitle(self.confirmButtonTitle, for: .normal)
        self.confirmButton = button
        if #available(iOS 9.0, *) {
            let inset: CGFloat = 10
            button.topAnchor.constraint(equalTo: contentView.topAnchor, constant: inset).isActive = true
            button.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: inset).isActive = true
            button.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -inset).isActive = true
            let bottomConstraint = button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -inset)
            if #available(iOS 11.0, *) {
                bottomConstraint.constant -= safeAreaInsets?.bottom ?? 0.0
            }
            bottomConstraint.isActive = true
        }
    }
	
	func getCurrentLocation() {
		locationManager.requestWhenInUseAuthorization()
		locationManager.startUpdatingLocation()
	}
	
    @objc func currentLocationPressed() {
		showCurrentLocation()
	}
	
	func showCurrentLocation(_ animated: Bool = true) {
		let listener = CurrentLocationListener(once: true) { [weak self] location in
			self?.showCoordinates(location.coordinate, animated: animated)
		}
		currentLocationListeners.append(listener)
        getCurrentLocation()
	}

    private func dismiss() {
        if let navigation = navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }
	
	func updateAnnotation() {
        if self.shouldShowAnnotations == false {
            return
        }
        mapView.removeAnnotations(mapView.annotations)
        if let location = location {
            mapView.addAnnotation(location)
            mapView.selectAnnotation(location, animated: true)
        }
	}
	
	func showCoordinates(_ coordinate: CLLocationCoordinate2D, animated: Bool = true) {
		let region = MKCoordinateRegionMakeWithDistance(coordinate, resultRegionDistance, resultRegionDistance)
		mapView.setRegion(region, animated: animated)
	}

    func selectLocation(location: CLLocation, completion: (()->())? = nil) {
        var annotation: MKPointAnnotation?
        if self.shouldShowAnnotations {
            // add point annotation to map
            let ann = MKPointAnnotation()
            ann.coordinate = location.coordinate
            mapView.addAnnotation(ann)
            annotation = ann
        }

        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { response, error in
            if let error = error as NSError?, error.code != 10 { // ignore cancelGeocode errors
                // show error and remove annotation
                let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: { _ in }))
                self.present(alert, animated: true) {
                    if let annotation = annotation {
                        self.mapView.removeAnnotation(annotation)
                    }
                }
            } else if let placemark = response?.first {
                // get POI name from placemark if any
                let name = placemark.areasOfInterest?.first

                // pass user selected location too
                self.location = Location(name: name, location: location, placemark: placemark)
                self.setConfirmButton(enabled: true)
            }
            completion?()
        }
    }

    @objc func confirmButtonAction(sender: Any) {
        let location = CLLocation(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
        if let location = self.location {
            self.completion?(location)
            self.dismiss()
        } else {
            self.selectLocation(location: location) {
                self.completion?(self.location)
                self.dismiss()
            }
        }
    }

    @objc func didDragViewGestureRecognizerAction(sender: UIGestureRecognizer) {
        if sender.state == .ended {
            self.mapChangedFromUserInteraction = true
        }
    }
}

extension LocationPickerViewController: CLLocationManagerDelegate {
	public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		guard let location = locations.first else { return }
        currentLocationListeners.forEach { $0.action(location) }
		currentLocationListeners = currentLocationListeners.filter { !$0.once }
		manager.stopUpdatingLocation()
	}
}

// MARK: Searching

extension LocationPickerViewController: UISearchResultsUpdating {
	public func updateSearchResults(for searchController: UISearchController) {
		guard let term = searchController.searchBar.text else { return }
		
		searchTimer?.invalidate()

		let searchTerm = term.trimmingCharacters(in: CharacterSet.whitespaces)
		
		if searchTerm.isEmpty {
			results.locations = historyManager.history()
			results.isShowingHistory = true
			results.tableView.reloadData()
		} else {
            self.search(for: searchTerm)
		}
	}

    func search(for searchTerm: String) {
        // clear old results
        showItemsForSearchResult(nil)

        searchTimer = Timer.scheduledTimer(timeInterval: 0.2,
                                           target: self, selector: #selector(LocationPickerViewController.searchFromTimer(_:)),
                                           userInfo: [LocationPickerViewController.SearchTermKey: searchTerm],
                                           repeats: false)
    }
	
    @objc func searchFromTimer(_ timer: Timer) {
		guard let userInfo = timer.userInfo as? [String: AnyObject],
			let term = userInfo[LocationPickerViewController.SearchTermKey] as? String
			else { return }
		
		let request = MKLocalSearchRequest()
		request.naturalLanguageQuery = term
		
		if let location = locationManager.location, useCurrentLocationAsHint {
			request.region = MKCoordinateRegion(center: location.coordinate,
				span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
		}
		
		localSearch?.cancel()
		localSearch = MKLocalSearch(request: request)
		localSearch!.start { response, _ in
			self.showItemsForSearchResult(response)
		}
	}
	
	func showItemsForSearchResult(_ searchResult: MKLocalSearchResponse?) {
		results.locations = searchResult?.mapItems.map { Location(name: $0.name, placemark: $0.placemark) } ?? []
		results.isShowingHistory = false
		results.tableView.reloadData()
	}
	
	func selectedLocation(_ location: Location) {
		// dismiss search results
		dismiss(animated: true) {
			// set location, this also adds annotation
			self.location = location
			self.showCoordinates(location.coordinate)
			
			self.historyManager.addToHistory(location)
		}
	}
}

// MARK: Selecting location with gesture

extension LocationPickerViewController {
    @objc func addLocation(_ gestureRecognizer: UIGestureRecognizer) {
        if !self.shouldShowAnnotations {
            return
        }
		if gestureRecognizer.state == .began {
			let point = gestureRecognizer.location(in: mapView)
			let coordinates = mapView.convert(point, toCoordinateFrom: mapView)
			let location = CLLocation(latitude: coordinates.latitude, longitude: coordinates.longitude)
			
			// clean location, cleans out old annotation too
			self.location = nil
            selectLocation(location: location)
		}
	}
}

// MARK: MKMapViewDelegate

extension LocationPickerViewController: MKMapViewDelegate {

    public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        if mapChangedFromUserInteraction {
            let location = CLLocation(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            self.selectLocation(location: location)
            mapChangedFromUserInteraction = false
        }
    }

	public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
		if annotation is MKUserLocation {
            return nil
        }
		
		let pin = MKPinAnnotationView(annotation: annotation, reuseIdentifier: "annotation")
		pin.pinColor = .green
		// drop only on long press gesture
		let fromLongPress = annotation is MKPointAnnotation
		pin.animatesDrop = fromLongPress
		pin.rightCalloutAccessoryView = selectLocationButton()
		pin.canShowCallout = !fromLongPress
		return pin
	}
	
	func selectLocationButton() -> UIButton {
		let button = UIButton(frame: CGRect(x: 0, y: 0, width: 70, height: 30))
		button.setTitle(selectButtonTitle, for: UIControlState())
        if let titleLabel = button.titleLabel {
            let width = titleLabel.textRect(forBounds: CGRect(x: 0, y: 0, width: Int.max, height: 30), limitedToNumberOfLines: 1).width
            button.frame.size = CGSize(width: width, height: 30.0)
        }
		button.setTitleColor(view.tintColor, for: UIControlState())
		return button
	}
	
	public func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
		completion?(location)
		if let navigation = navigationController, navigation.viewControllers.count > 1 {
			navigation.popViewController(animated: true)
		} else {
			presentingViewController?.dismiss(animated: true, completion: nil)
		}
	}
	
	public func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {

        if self.shouldHideUserLocation {
            let userView = mapView.view(for: mapView.userLocation)
            userView?.isHidden = true
        }

		let pins = mapView.annotations.filter { $0 is MKPinAnnotationView }
		assert(pins.count <= 1, "Only 1 pin annotation should be on map at a time")

        if let userPin = views.first(where: { $0.annotation is MKUserLocation }) {
            userPin.canShowCallout = false
        }
	}
}

extension LocationPickerViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: UISearchBarDelegate

extension LocationPickerViewController: UISearchBarDelegate {
	public func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
		// dirty hack to show history when there is no text in search bar
		// to be replaced later (hopefully)
		if let text = searchBar.text, text.isEmpty {
			searchBar.text = " "
		}
	}
	
	public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
		// remove location if user presses clear or removes text
		if searchText.isEmpty {
			location = nil
			searchBar.text = " "
		}
	}
}
