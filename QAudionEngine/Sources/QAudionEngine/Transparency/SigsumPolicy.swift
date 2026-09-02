import Foundation

/// TRUST-1 residual — Sigsum trust policy: known logs, known witnesses, and
/// the quorum rule a cosigned tree head must satisfy. Semantics match
/// `sigsum-go`'s policy-file format (`doc/policy.md` §"Defining a witness
/// group": `group <name> all|any|<k> <member>...`, quorum reference by
/// name, groups may nest).
public struct SigsumLog: Equatable {
    public let name: String
    public let publicKey: Data
    public let url: String?

    public init(name: String, publicKey: Data, url: String?) {
        self.name = name
        self.publicKey = publicKey
        self.url = url
    }
}

public struct SigsumWitness: Equatable {
    public let name: String
    public let publicKey: Data
    public let url: String?

    public init(name: String, publicKey: Data, url: String?) {
        self.name = name
        self.publicKey = publicKey
        self.url = url
    }
}

/// A member of a quorum group — either a single named witness, or another
/// (previously declared) group, exactly mirroring `sigsum-go`'s policy-file
/// grammar (`group <name> ... <member>...` where `<member>` is a witness or
/// group name).
public enum SigsumQuorumMember: Equatable {
    case witness(String)
    case group(String)
}

/// `group <name> <threshold> <member>...` — considered "witnessed" once at
/// least `threshold` of its members are (each member being either a single
/// witness's own cosignature, or that same recursive rule for a nested
/// group). `all` => `threshold == members.count`; `any` => `threshold == 1`.
public struct SigsumQuorumGroup: Equatable {
    public let name: String
    public let threshold: Int
    public let members: [SigsumQuorumMember]

    public init(name: String, threshold: Int, members: [SigsumQuorumMember]) {
        self.name = name
        self.threshold = threshold
        self.members = members
    }
}

public struct SigsumPolicy {
    public let name: String
    public let logs: [SigsumLog]
    public let witnesses: [SigsumWitness]
    public let groups: [SigsumQuorumGroup]
    public let quorumGroupName: String

    public init(name: String, logs: [SigsumLog], witnesses: [SigsumWitness], groups: [SigsumQuorumGroup], quorumGroupName: String) {
        self.name = name
        self.logs = logs
        self.witnesses = witnesses
        self.groups = groups
        self.quorumGroupName = quorumGroupName
    }

    public func witness(named name: String) -> SigsumWitness? {
        witnesses.first { $0.name == name }
    }

    public func group(named name: String) -> SigsumQuorumGroup? {
        groups.first { $0.name == name }
    }

    /// Resolve a log by the SHA-256 hash of its public key (what a proof
    /// bundle's `log=` line actually carries — never trust a bare pubkey
    /// claim without this bitwise check, per the accept-decision checklist).
    public func log(withKeyHash keyHash: Data) -> SigsumLog? {
        logs.first { SigsumCrypto.sha256($0.publicKey) == keyHash }
    }

    /// Resolve a witness by the SHA-256 hash of its public key (what a
    /// `cosignature=` line's first field carries).
    public func witness(withKeyHash keyHash: Data) -> SigsumWitness? {
        witnesses.first { SigsumCrypto.sha256($0.publicKey) == keyHash }
    }

    /// True iff `verifiedWitnessNames` (witnesses whose cosignature has
    /// ALREADY been checked cryptographically valid by the caller — this
    /// function does no signature verification of its own) satisfy the
    /// policy's quorum, recursively through nested groups.
    public func quorumSatisfied(by verifiedWitnessNames: Set<String>) -> Bool {
        guard let top = group(named: quorumGroupName) else { return false }
        return evaluate(top, verified: verifiedWitnessNames, depth: 0)
    }

    /// `depth` guards against a pathological/malformed policy (self- or
    /// mutually-referencing groups) turning this into infinite recursion —
    /// a real policy file can only reference groups declared on EARLIER
    /// lines, so 16 levels is far more nesting than any legitimate policy
    /// (both policies hardcoded in this file use at most one level).
    private func evaluate(_ g: SigsumQuorumGroup, verified: Set<String>, depth: Int) -> Bool {
        guard depth < 16 else { return false }
        var satisfiedCount = 0
        for member in g.members {
            let memberSatisfied: Bool
            switch member {
            case .witness(let name):
                memberSatisfied = verified.contains(name)
            case .group(let name):
                if let sub = group(named: name) {
                    memberSatisfied = evaluate(sub, verified: verified, depth: depth + 1)
                } else {
                    memberSatisfied = false
                }
            }
            if memberSatisfied { satisfiedCount += 1 }
        }
        return satisfiedCount >= g.threshold
    }
}

extension SigsumPolicy {

    /// **DEV/TEST target** — `sigsum-test-2025-3`. Used to actually build
    /// and test the submitter/verifier against a REAL running log (see
    /// `SigsumMerkleTests`/`SigsumVerifierTests`' live-fixture cases,
    /// sourced from `test.sigsum.org/barreleye`).
    ///
    /// Fetched VERBATIM from the canonical source — `gh api
    /// repos/sigsum/sigsum-go/contents/pkg/policy/builtin/sigsum-test-2025-3.builtin-policy`
    /// against `github.com/sigsum/sigsum-go` (2026-09-02) — not retyped from
    /// a secondary description. The quorum is `4 of {glasklar-test-witnesses(2-of-3),
    /// witness.navigli.sunlight.geomys.org, remora.n621.de, witness.stagemole.eu,
    /// tillitis.se/test-witness-1, transparency.dev/DEV:witness-little-garden}`
    /// — i.e. up to 4-of-6 at the top level, with one of those six itself
    /// being a nested 2-of-3 group (this is the "4-of-6 witness quorum"
    /// referred to elsewhere as this policy's headline shape).
    public static let sigsumTest2025_3: SigsumPolicy = {
        let logs = [
            SigsumLog(
                name: "test.sigsum.org/barreleye",
                publicKey: SigsumHex.decode("4644af2abd40f4895a003bca350f9d5912ab301a49c77f13e5b6d905c20a5fe6")!,
                url: "https://test.sigsum.org/barreleye"
            ),
            SigsumLog(
                name: "serviceberry.tlog.stagemole.eu",
                publicKey: SigsumHex.decode("47e481606d8acba747a6b053d6c2d191605fb122175d410a1202a91430abce39")!,
                url: "https://serviceberry.tlog.stagemole.eu"
            ),
        ]
        let witnesses = [
            SigsumWitness(name: "poc.sigsum.org/nisse", publicKey: SigsumHex.decode("1c25f8a44c635457e2e391d1efbca7d4c2951a0aef06225a881e46b98962ac6c")!, url: nil),
            SigsumWitness(name: "rgdd.se/poc-witness", publicKey: SigsumHex.decode("28c92a5a3a054d317c86fc2eeb6a7ab2054d6217100d0be67ded5b74323c5806")!, url: nil),
            SigsumWitness(name: "witness1.smartit.nu/witness1", publicKey: SigsumHex.decode("f4855a0f46e8a3e23bb40faf260ee57ab8a18249fa402f2ca2d28a60e1a3130e")!, url: nil),
            SigsumWitness(name: "witness.navigli.sunlight.geomys.org", publicKey: SigsumHex.decode("dcbf728e02d479f5a7e20dc09adf525833ed6e797526517aeb07fc6854849fc6")!, url: nil),
            SigsumWitness(name: "remora.n621.de", publicKey: SigsumHex.decode("ebcdeb78e7fdb2ef9227b2c1ef11e94600b55b4d6d9a57877e31ee89e59adc36")!, url: nil),
            SigsumWitness(name: "witness.stagemole.eu", publicKey: SigsumHex.decode("4a921b7caef58ae670cdc11ef4184f1c058f7b9259a9107a969f69fa54aa496f")!, url: nil),
            SigsumWitness(name: "tillitis.se/test-witness-1", publicKey: SigsumHex.decode("636582aec12f32c18a21733db9e3f718058ee7aaec6dbe4eb81781e0f4300c6e")!, url: nil),
            SigsumWitness(name: "transparency.dev/DEV:witness-little-garden", publicKey: SigsumHex.decode("2b6eb0ec483503544cde4e8fc1ce6d1921db21dffccc186865f808f7625443cc")!, url: nil),
        ]
        let groups = [
            SigsumQuorumGroup(
                name: "glasklar-test-witnesses",
                threshold: 2,
                members: [.witness("poc.sigsum.org/nisse"), .witness("rgdd.se/poc-witness"), .witness("witness1.smartit.nu/witness1")]
            ),
            SigsumQuorumGroup(
                name: "quorum-rule",
                threshold: 4,
                members: [
                    .group("glasklar-test-witnesses"),
                    .witness("witness.navigli.sunlight.geomys.org"),
                    .witness("remora.n621.de"),
                    .witness("witness.stagemole.eu"),
                    .witness("tillitis.se/test-witness-1"),
                    .witness("transparency.dev/DEV:witness-little-garden"),
                ]
            ),
        ]
        return SigsumPolicy(name: "sigsum-test-2025-3", logs: logs, witnesses: witnesses, groups: groups, quorumGroupName: "quorum-rule")
    }()

    /// **PRODUCTION target** — `sigsum-generic-2025-1`. Present so the
    /// verifier is ready once the server side lands, but NOT wired to any
    /// live submission path yet and this app does NOT submit real user
    /// data against it today.
    ///
    /// Two real-world prerequisites are still outstanding, and are NOT
    /// something this client can do on its own:
    ///
    /// 1. **DNS TXT record.** Rate-limited submission (`log.md` §4) needs a
    ///    `_sigsum_v1.bcrypto.com` TXT record publishing the hex-encoded
    ///    public half of a dedicated rate-limit Ed25519 keypair (distinct
    ///    from any leaf-signing/identity key — see `SigsumCrypto`'s
    ///    submit-token helpers, which ARE implemented and tested here,
    ///    ready for that key once it exists). **Only the domain owner
    ///    (bcrypto.com) can publish this DNS record** — it is not something
    ///    any client-side code change can do.
    /// 2. **Server-side submitter.** A separate agent in the batch that
    ///    produced this file is building the bcrypto-server component that
    ///    actually submits identity bindings to this log and returns
    ///    `SigsumProofBundle`s to clients; this file cannot see that work.
    ///
    /// Fetched VERBATIM from `gh api
    /// repos/sigsum/sigsum-go/contents/pkg/policy/builtin/sigsum-generic-2025-1.builtin-policy`
    /// against `github.com/sigsum/sigsum-go` (2026-09-02). Log key hashes
    /// cross-checked against Glasklar Teknik's own operational doc for
    /// seasalp (`git.glasklar.is/glasklar/services/sigsum-logs`, mirrored
    /// into this policy file's own header comment) — both sources agree
    /// byte-for-byte. Quorum: 2-of-3 (`witness.glasklar.is`,
    /// `witness.mullvad.net`, `tillitis.se/tillitis-witness-1`).
    public static let sigsumGeneric2025_1: SigsumPolicy = {
        let logs = [
            SigsumLog(
                name: "seasalp.glasklar.is",
                publicKey: SigsumHex.decode("0ec7e16843119b120377a73913ac6acbc2d03d82432e2c36b841b09a95841f25")!,
                url: "https://seasalp.glasklar.is"
            ),
            SigsumLog(
                name: "ginkgo.tlog.mullvad.net",
                publicKey: SigsumHex.decode("f00c159663d09bbda6131ee1816863b6adcacfe80b0b288000b11aba8fe38314")!,
                url: "https://ginkgo.tlog.mullvad.net"
            ),
        ]
        let witnesses = [
            SigsumWitness(name: "witness.glasklar.is", publicKey: SigsumHex.decode("b2106db9065ec97f25e09c18839216751a6e26d8ed8b41e485a563d3d1498536")!, url: nil),
            SigsumWitness(name: "witness.mullvad.net", publicKey: SigsumHex.decode("15d6d0141543247b74bab3c1076372d9c894f619c376d64b29aa312cc00f61ad")!, url: nil),
            SigsumWitness(name: "tillitis.se/tillitis-witness-1", publicKey: SigsumHex.decode("076be8c9ee7ea60916f0df3608c945d7730082ecb37749dad2c9ed339fea770c")!, url: nil),
        ]
        let groups = [
            SigsumQuorumGroup(
                name: "quorum-rule",
                threshold: 2,
                members: [.witness("witness.glasklar.is"), .witness("witness.mullvad.net"), .witness("tillitis.se/tillitis-witness-1")]
            ),
        ]
        return SigsumPolicy(name: "sigsum-generic-2025-1", logs: logs, witnesses: witnesses, groups: groups, quorumGroupName: "quorum-rule")
    }()
}
