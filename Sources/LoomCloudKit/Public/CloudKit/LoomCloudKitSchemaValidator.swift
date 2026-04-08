//
//  LoomCloudKitSchemaValidator.swift
//  Loom
//
//  Pre-flight CloudKit schema validation with actionable diagnostics.
//

import CloudKit
import Foundation
import Loom

/// Result of a single schema validation check.
public struct LoomCloudKitSchemaIssue: Sendable, Identifiable {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let id = UUID()
    public let severity: Severity
    public let recordType: String?
    public let field: String?
    public let message: String
    public let remediation: String

    public init(
        severity: Severity,
        recordType: String?,
        field: String?,
        message: String,
        remediation: String
    ) {
        self.severity = severity
        self.recordType = recordType
        self.field = field
        self.message = message
        self.remediation = remediation
    }
}

/// Validates that the CloudKit container schema matches the fields expected by Loom.
///
/// Call ``validate(configuration:container:)`` during app startup or from a
/// diagnostics view to get a list of actionable issues before CloudKit
/// operations start failing with opaque errors.
///
/// ```swift
/// let issues = await LoomCloudKitSchemaValidator.validate(
///     configuration: cloudKitConfig,
///     container: CKContainer(identifier: cloudKitConfig.containerIdentifier)
/// )
/// for issue in issues {
///     print("[\(issue.severity)] \(issue.message)")
///     print("  Fix: \(issue.remediation)")
/// }
/// ```
public enum LoomCloudKitSchemaValidator {

    /// Expected fields for the device record type.
    private static let deviceFields: [(name: String, description: String)] = [
        ("name", "String – device display name"),
        ("deviceType", "String – mac, iPad, iPhone, or vision"),
        ("lastSeen", "Date/Time – last activity timestamp"),
        ("identityKeyID", "String – identity key identifier"),
        ("identityPublicKey", "Bytes – public identity key"),
    ]

    /// Expected fields for the peer record type.
    private static let peerFields: [(name: String, description: String)] = [
        ("deviceID", "String – stable device UUID"),
        ("name", "String – peer display name"),
        ("createdAt", "Date/Time – creation timestamp"),
        ("lastSeen", "Date/Time – last activity timestamp"),
        ("deviceType", "String – device type"),
        ("advertisementBlob", "Bytes – serialized peer advertisement"),
        ("identityPublicKey", "Bytes – public identity key"),
        ("remoteAccessEnabled", "Int64 – whether remote access is on"),
        ("relaySessionID", "String – signaling session identifier"),
        ("bootstrapMetadataBlob", "Bytes – serialized bootstrap metadata"),
    ]

    /// Expected fields for the participant identity record type.
    private static let participantIdentityFields: [(name: String, description: String)] = [
        ("keyID", "String – identity key identifier"),
        ("publicKey", "Bytes – public identity key"),
        ("lastSeen", "Date/Time – last activity timestamp"),
    ]

    /// Runs pre-flight validation of the CloudKit schema against the provided configuration.
    ///
    /// - Parameters:
    ///   - configuration: The ``LoomCloudKitConfiguration`` describing expected record types and zones.
    ///   - container: The `CKContainer` to probe. When `nil`, one is created from the configuration.
    /// - Returns: An array of issues. An empty array means no problems were detected.
    public static func validate(
        configuration: LoomCloudKitConfiguration,
        container: CKContainer? = nil
    ) async -> [LoomCloudKitSchemaIssue] {
        var issues: [LoomCloudKitSchemaIssue] = []

        let ckContainer = container ?? CKContainer(identifier: configuration.containerIdentifier)

        let accountStatus = await checkAccountStatus(container: ckContainer)
        switch accountStatus {
        case .available:
            break
        case .noAccount:
            issues.append(LoomCloudKitSchemaIssue(
                severity: .error,
                recordType: nil,
                field: nil,
                message: "No iCloud account is signed in on this device.",
                remediation: "Sign in to iCloud in Settings > Apple Account > iCloud."
            ))
            return issues
        case .restricted:
            issues.append(LoomCloudKitSchemaIssue(
                severity: .error,
                recordType: nil,
                field: nil,
                message: "iCloud access is restricted by device management policy.",
                remediation: "Contact your device administrator to enable iCloud access."
            ))
            return issues
        default:
            issues.append(LoomCloudKitSchemaIssue(
                severity: .warning,
                recordType: nil,
                field: nil,
                message: "iCloud account status could not be determined (status: \(accountStatus.rawValue)).",
                remediation: "Ensure the device has network connectivity and iCloud is enabled."
            ))
        }

        async let deviceIssues = probeRecordType(
            container: ckContainer,
            database: ckContainer.privateCloudDatabase,
            recordType: configuration.deviceRecordType,
            expectedFields: deviceFields,
            zone: nil,
            tip: "This record type stores device registrations."
        )
        async let peerIssues = probeRecordType(
            container: ckContainer,
            database: ckContainer.privateCloudDatabase,
            recordType: configuration.peerRecordType,
            expectedFields: peerFields,
            zone: CKRecordZone.ID(
                zoneName: configuration.peerZoneName,
                ownerName: CKCurrentUserDefaultName
            ),
            tip: "This record type stores peer advertisements."
        )
        async let identityIssues = probeRecordType(
            container: ckContainer,
            database: ckContainer.privateCloudDatabase,
            recordType: configuration.participantIdentityRecordType,
            expectedFields: participantIdentityFields,
            zone: CKRecordZone.ID(
                zoneName: configuration.peerZoneName,
                ownerName: CKCurrentUserDefaultName
            ),
            tip: "This record type stores participant identity keys for trust verification."
        )

        issues.append(contentsOf: await deviceIssues)
        issues.append(contentsOf: await peerIssues)
        issues.append(contentsOf: await identityIssues)

        return issues
    }

    // MARK: - Private

    private static func checkAccountStatus(
        container: CKContainer
    ) async -> CKAccountStatus {
        do {
            return try await container.accountStatus()
        } catch {
            return .couldNotDetermine
        }
    }

    private static func probeRecordType(
        container: CKContainer,
        database: CKDatabase,
        recordType: String,
        expectedFields: [(name: String, description: String)],
        zone: CKRecordZone.ID?,
        tip: String
    ) async -> [LoomCloudKitSchemaIssue] {
        var issues: [LoomCloudKitSchemaIssue] = []

        if let zone {
            do {
                _ = try await database.recordZone(for: zone)
            } catch {
                let ckError = error as? CKError
                if ckError?.code == .zoneNotFound {
                    issues.append(LoomCloudKitSchemaIssue(
                        severity: .warning,
                        recordType: recordType,
                        field: nil,
                        message: "Zone \"\(zone.zoneName)\" does not exist yet. It will be created on first write.",
                        remediation: "No action needed — the zone is created automatically. If queries fail, verify the zone name in CloudKit Console."
                    ))
                }
            }
        }

        let query = CKQuery(
            recordType: recordType,
            predicate: NSPredicate(value: true)
        )

        do {
            let (results, _) = try await database.records(
                matching: query,
                inZoneWith: zone,
                resultsLimit: 1
            )

            if let first = results.first {
                switch first.1 {
                case let .success(record):
                    let existingKeys = Set(record.allKeys())
                    for field in expectedFields where !existingKeys.contains(field.name) {
                        issues.append(LoomCloudKitSchemaIssue(
                            severity: .warning,
                            recordType: recordType,
                            field: field.name,
                            message: "Field \"\(field.name)\" not found on existing \(recordType) record.",
                            remediation: "Add field \"\(field.name)\" (\(field.description)) to \(recordType) in CloudKit Console, then deploy to production."
                        ))
                    }
                case let .failure(recordError):
                    issues.append(LoomCloudKitSchemaIssue(
                        severity: .warning,
                        recordType: recordType,
                        field: nil,
                        message: "Could not read sample \(recordType) record: \(recordError.localizedDescription)",
                        remediation: "Check CloudKit Console for schema or permission issues with \(recordType)."
                    ))
                }
            }
        } catch {
            let ckError = error as? CKError

            if ckError?.code == .unknownItem {
                issues.append(LoomCloudKitSchemaIssue(
                    severity: .error,
                    recordType: recordType,
                    field: nil,
                    message: "Record type \"\(recordType)\" does not exist in the CloudKit schema. \(tip)",
                    remediation: """
                        Open CloudKit Console → select your container → Schema → Record Types → \
                        create \"\(recordType)\" with fields: \
                        \(expectedFields.map { "\($0.name) (\($0.description))" }.joined(separator: ", ")). \
                        Then deploy the schema to production.
                        """
                ))
            } else if let msg = ckError?.localizedDescription,
                      msg.lowercased().contains("cannot create new type") {
                issues.append(LoomCloudKitSchemaIssue(
                    severity: .error,
                    recordType: recordType,
                    field: nil,
                    message: "Production schema is missing record type \"\(recordType)\". CloudKit cannot auto-create types in production.",
                    remediation: "Deploy the development schema (which includes \(recordType)) to production via CloudKit Console → Deploy Schema to Production."
                ))
            } else {
                issues.append(LoomCloudKitSchemaIssue(
                    severity: .warning,
                    recordType: recordType,
                    field: nil,
                    message: "Could not query \(recordType): \(error.localizedDescription)",
                    remediation: "Verify CloudKit container \"\(container.containerIdentifier ?? "unknown")\" is configured correctly and the device has network access."
                ))
            }
        }

        return issues
    }
}
