import Foundation

enum FieldCodedSupport {
    static func canRepairFieldCoded(codec: String?) -> Bool {
        codec == "h264"
    }

    static func requiresCopyOnlyCuts(fieldCoded: Bool?, codec: String?) -> Bool {
        fieldCoded == true && canRepairFieldCoded(codec: codec)
    }
}
