import CoreLocation

/// Published WGS84 coordinates used as ground truth for marker placement.
/// The Eiffel Tower is the reference pin: both latitude and longitude sit inside
/// ±90, so a lat/lon swap still parses as a valid coordinate and must be caught
/// by comparing the pin to this known point.
enum Landmark {
    /// Eiffel Tower, Paris (Champ de Mars).
    static let eiffelTower = CLLocationCoordinate2D(latitude: 48.858370, longitude: 2.294481)
    /// Louvre Pyramid, Paris.
    static let louvrePyramid = CLLocationCoordinate2D(latitude: 48.860611, longitude: 2.337633)

    static var eiffelTowerGeoURI: String {
        String(format: "geo:%.6f,%.6f", eiffelTower.latitude, eiffelTower.longitude)
    }

    static var louvrePyramidGeoURI: String {
        String(format: "geo:%.6f,%.6f", louvrePyramid.latitude, louvrePyramid.longitude)
    }

    /// Offline stand-in for an Apple Maps automobile trace: Quai Branly →
    /// Cours la Reine → Concorde → Rue de Rivoli. Used by UI tests so the
    /// line follows streets without calling MapKit.
    static let eiffelToLouvreRoad: [CLLocationCoordinate2D] = [
        eiffelTower,
        CLLocationCoordinate2D(latitude: 48.85940, longitude: 2.29780),
        CLLocationCoordinate2D(latitude: 48.86240, longitude: 2.30150),
        CLLocationCoordinate2D(latitude: 48.86330, longitude: 2.30580),
        CLLocationCoordinate2D(latitude: 48.86380, longitude: 2.31040),
        CLLocationCoordinate2D(latitude: 48.86370, longitude: 2.31350),
        CLLocationCoordinate2D(latitude: 48.86480, longitude: 2.31880),
        CLLocationCoordinate2D(latitude: 48.86560, longitude: 2.32110),
        CLLocationCoordinate2D(latitude: 48.86470, longitude: 2.32750),
        CLLocationCoordinate2D(latitude: 48.86320, longitude: 2.33340),
        louvrePyramid
    ]
}
