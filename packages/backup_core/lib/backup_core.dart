/// Encrypted backup + both-donor migration for the fusion rebuild.
///
/// Three jobs, all producing/consuming **DB-agnostic row maps** so the
/// storage adapter (Drift native / drift-wasm) stays an app concern:
///
///  1. **Our envelope** — versioned JSON row-map payload, encrypted with the
///     real `sanctuary_auth_core` OHBK format (BIP39 phrase -> HKDF
///     appDomain -> ChaCha20-Poly1305 + AAD context). Consents never travel.
///  2. **Trellis donor import** — decrypt a donor `.ohbk` (appDomain
///     `trellis`, AAD `trellis-backup/v1`) and map courses/cards into row
///     maps. SM-2 state maps 1:1.
///  3. **ohPrimer donor import** — parse the donor's plaintext JSON export
///     with the donor's own sanitization ported (prototype-pollution key
///     rejection, id re-scoping, dedupe). ML caches and model consents are
///     deliberately dropped.
///
/// Every import returns a tiny pure [MigrationReport] the UI can show calmly.
library;

export 'src/espalier_backup.dart';
export 'src/migration_report.dart';
export 'src/ohprimer_import.dart';
export 'src/ohprimer_sanitize.dart';
export 'src/row_payload.dart';
export 'src/trellis_import.dart';
