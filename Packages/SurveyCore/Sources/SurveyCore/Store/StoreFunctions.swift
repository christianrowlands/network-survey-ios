import Foundation
import GRDB
import NSMessaging

/// SQL functions the store's queries use, added to every connection.
enum StoreFunctions {
    /// `findMyDevice(advData)`: the `FindMyDevice` raw value of a BLE
    /// device's last advertisement, or NULL when it is not Find My. Reading
    /// the blob at query time needs no stored column, so databases from
    /// earlier versions filter the same way without a migration.
    static let findMyDevice = DatabaseFunction("findMyDevice", argumentCount: 1, pure: true) { values in
        guard let data = Data.fromDatabaseValue(values[0]) else { return nil }
        return FindMy.device(advertisingData: data)?.rawValue
    }

    static func register(_ db: Database) {
        db.add(function: findMyDevice)
    }

    /// The store's connection configuration, with these functions added.
    static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in register(db) }
        return config
    }
}
