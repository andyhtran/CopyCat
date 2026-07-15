import Foundation
import XCTest
@testable import CopyCat

final class InstallOriginTests: XCTestCase {
    func testHomebrewCaskroomDetected() {
        let url = URL(fileURLWithPath: "/opt/homebrew/Caskroom/copycat/1.0/CopyCat.app")
        XCTAssertTrue(InstallOrigin.isHomebrewCask(appBundleURL: url))
    }

    func testHomebrewCaskroomAlternatePathDetected() {
        let url = URL(fileURLWithPath: "/usr/local/Homebrew/Caskroom/copycat/1.0/CopyCat.app")
        XCTAssertTrue(InstallOrigin.isHomebrewCask(appBundleURL: url))
    }

    func testApplicationsPathNotDetected() {
        let url = URL(fileURLWithPath: "/Applications/CopyCat.app")
        XCTAssertFalse(InstallOrigin.isHomebrewCask(appBundleURL: url))
    }

    func testUserApplicationsPathNotDetected() {
        let url = URL(fileURLWithPath: "/Users/someone/Applications/CopyCat.app")
        XCTAssertFalse(InstallOrigin.isHomebrewCask(appBundleURL: url))
    }
}
