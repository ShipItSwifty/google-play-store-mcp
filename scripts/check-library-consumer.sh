#!/usr/bin/env bash
# Verify SemVer consumption and both supported Crypto majors using an isolated snapshot.
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/package" "$check_dir/consumer/Sources/Consumer"
cp "$repo_dir/Package.swift" "$check_dir/package/"
cp -R "$repo_dir/Sources" "$repo_dir/Tests" "$check_dir/package/"
git -C "$check_dir/package" init -q
git -C "$check_dir/package" add .
git -C "$check_dir/package" -c user.name='Library Consumer Check' -c user.email='consumer-check@localhost' \
  -c commit.gpgsign=false commit -qm 'Consumer fixture'
git -C "$check_dir/package" tag 0.0.0
cat > "$check_dir/consumer/Sources/Consumer/main.swift" <<'SWIFT'
import GoogleAuthKit
import GooglePlayKit
let credentials = GoogleServiceAccountCredentials(
    clientEmail: "test@example.com", privateKey: "test", tokenUri: "https://oauth2.googleapis.com/token")
let client = GooglePlayClient(credentials: credentials)
let targeting = GooglePlayCountryTargeting(countries: ["US"], includeRestOfWorld: false)
let release = GooglePlayRelease(status: .inProgress, userFraction: 0.1, countryTargeting: targeting, inAppUpdatePriority: 5)
print(release.status.rawValue)
SWIFT
for crypto_version in 4.5.2 5.0.0; do
  cat > "$check_dir/consumer/Package.swift" <<SWIFT
// swift-tools-version: 6.3
import PackageDescription
let package = Package(
    name: "Consumer", platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "file://$check_dir/package", exact: "0.0.0"),
        .package(url: "https://github.com/apple/swift-crypto", exact: "$crypto_version"),
    ],
    targets: [.executableTarget(name: "Consumer", dependencies: [
        .product(name: "GoogleAuthKit", package: "package"),
        .product(name: "GooglePlayKit", package: "package"),
        .product(name: "Crypto", package: "swift-crypto"),
    ])]
)
SWIFT
  echo "Checking SemVer library consumer with Crypto $crypto_version"
  swift build --package-path "$check_dir/consumer"
  # Exercise authentication signing and the Play client against this Crypto major too.
  swift package --package-path "$check_dir/package" resolve
  swift package --package-path "$check_dir/package" resolve swift-crypto --version "$crypto_version"
  swift test --package-path "$check_dir/package" --no-parallel \
    --filter 'GoogleServiceAccountJWTGeneratorTests|GoogleTokenExchangeTests|GooglePlayClientTests'
done
