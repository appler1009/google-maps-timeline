import MapKit

final class KindPolyline: MKPolyline {
    var kind: TravelKind = .automobile
}

final class VisitAnnotation: MKPointAnnotation {
    var semantic: String?
    var visitID: String?
}

enum TimelineMapPlotter {
    static func install(on map: MKMapView, day: DayRecord?, place: PlaceRecord?, routed: [RoutedHop]) {
        if let day {
            addDayPaths(map: map, routed: routed)
            for visit in day.visits {
                guard let coordinate = visit.coordinate else { continue }
                map.addAnnotation(pin(visit: visit, coordinate: coordinate))
            }
        } else if let place, let coordinate = place.coordinate {
            map.addAnnotation(pin(place: place, coordinate: coordinate))
        }
    }

    static func pin(visit: TimelineVisit, coordinate: CLLocationCoordinate2D) -> VisitAnnotation {
        let pin = VisitAnnotation()
        pin.coordinate = coordinate
        pin.title = TimelineParser.semanticTitle(visit.semanticType) ?? "Place"
        pin.semantic = visit.semanticType
        pin.visitID = visit.id
        return pin
    }

    static func pin(place: PlaceRecord, coordinate: CLLocationCoordinate2D) -> VisitAnnotation {
        let pin = VisitAnnotation()
        pin.coordinate = coordinate
        pin.title = TimelineParser.semanticTitle(place.semanticType) ?? "Place"
        pin.semantic = place.semanticType
        return pin
    }

    static func addDayPaths(map: MKMapView, routed: [RoutedHop]) {
        for hop in routed where hop.points.count >= 2 {
            addPolyline(map: map, points: hop.points, kind: hop.kind)
        }
    }

    static func addPolyline(map: MKMapView, points: [CLLocationCoordinate2D], kind: TravelKind) {
        var coords = points
        let overlay = KindPolyline(coordinates: &coords, count: coords.count)
        overlay.kind = kind
        map.addOverlay(overlay, level: .aboveRoads)
    }
}
