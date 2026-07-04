import Foundation

/// Shared field-coded (PAFF) codec eligibility gate. Two features consult it: Clip
/// Doctor's damage-to-EOF repair (issue #54/#57), whose tail is always MBAFF H.264, and
/// the cut editor's copy-cut snapping (issue #96), which only has a validated recipe on
/// H.264 PAFF (ADR-0022's de-risk never covered MPEG-2/HEVC field-coded footage). Both
/// consult the *same* predicate so a codec neither route trusts can't drift out of sync
/// between "Doctor will repair this" and "the cut editor will snap this."
enum FieldCodedSupport {
    /// Whether a field-coded source of this codec is eligible for the H.264-only
    /// field-coded routes. `nil`/anything but `"h264"` is ineligible — a non-H.264
    /// field-coded clip takes neither Clip Doctor's damage-to-EOF repair (it would
    /// concat a mixed-codec tail) nor copy-cut snapping (no validated recipe).
    static func canRepairFieldCoded(codec: String?) -> Bool {
        codec == "h264"
    }

    /// Whether a clip takes the field-coded **copy-cut route** (issue #96): a *confirmed*
    /// field-coded source (`fieldCoded == true` — `nil`, still probing, does not qualify)
    /// in a codec the route covers. On such a clip the cut editor snaps every mark to a
    /// copy-valid boundary (`CopyCutSnapper`) and the export planner enforces that the
    /// resulting plan is copy segments only (`ExportError.fieldCodedPlanNotCopyOnly`) —
    /// both consult this one predicate so "the editor snapped it" and "the planner
    /// requires it snapped" can never disagree about which clips are on the route.
    static func requiresCopyOnlyCuts(fieldCoded: Bool?, codec: String?) -> Bool {
        fieldCoded == true && canRepairFieldCoded(codec: codec)
    }
}
