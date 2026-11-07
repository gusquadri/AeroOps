import Foundation
import Testing
import AeroCore
import AeroTestSupport

@Suite("Probe parser")
struct ProbeParserTests {
    private func capabilities(_ name: String) throws -> HostCapabilities {
        HostCapabilities(probeOutput: try Fixtures.string("probe/\(name).txt"))
    }

    @Test("VM as the dev user: docker works, the k3s kubeconfig does not")
    func vmDev() throws {
        let caps = try capabilities("vm-dev")
        #expect(caps == [.docker, .kubectl, .k3s, .dockerOK])
        #expect(!caps.dockerNeedsSetup)
        #expect(caps.kubernetesNeedsSetup)
        #expect(caps.suggestedKubectlPrefix == "sudo -n k3s kubectl")
    }

    @Test("VM as a user outside the docker group")
    func vmNoDocker() throws {
        let caps = try capabilities("vm-nodocker")
        #expect(caps == [.docker, .kubectl, .k3s])
        #expect(caps.dockerNeedsSetup)
        #expect(caps.kubernetesNeedsSetup)
    }

    @Test("VM as root: everything works")
    func vmRoot() throws {
        let caps = try capabilities("vm-root")
        #expect(caps == [.docker, .kubectl, .k3s, .dockerOK, .kubeOK])
        #expect(!caps.contains(.podman))
        #expect(!caps.dockerNeedsSetup)
        #expect(!caps.kubernetesNeedsSetup)
        #expect(caps.suggestedKubectlPrefix == nil)
    }

    @Test("containers without tools print nothing")
    func emptyProbes() throws {
        for name in ["devcontainer", "alpine-busybox"] {
            let caps = try capabilities(name)
            #expect(caps.isEmpty, "\(name)")
            #expect(!caps.dockerNeedsSetup)
            #expect(!caps.kubernetesNeedsSetup)
            #expect(caps.suggestedKubectlPrefix == nil)
        }
    }

    @Test("unknown tokens, CRLF, spaces and near-miss words are ignored")
    func junk() {
        let caps = HostCapabilities(probeOutput: "motd banner\r\ndocker\r\n  kubectl  kube-ok\nDOCKER\ndocker-okay\npodman2\n\u{0}")
        #expect(caps == [.docker, .kubectl, .kubeOK])
        #expect(HostCapabilities(probeOutput: "kubectl").suggestedKubectlPrefix == nil)
    }

    @Test("Codable round trip")
    func codable() throws {
        let caps: HostCapabilities = [.docker, .kubeOK]
        let data = try JSONEncoder().encode(caps)
        #expect(try JSONDecoder().decode(HostCapabilities.self, from: data) == caps)
    }
}
