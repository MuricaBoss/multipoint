import Foundation

class SignalingClient {
    let androidIP: String
    let port: Int = 8888
    
    init(androidIP: String) {
        self.androidIP = androidIP
    }
    
    func sendOffer(sdp: String) async throws -> String {
        guard let url = URL(string: "http://\(androidIP):\(port)/offer") else { 
            throw NSError(domain: "SignalingClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["type": "offer", "sdp": sdp]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "SignalingClient", code: status, userInfo: [NSLocalizedDescriptionKey: "Server error \(status)"])
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answerSdp = json["sdp"] as? String else {
            throw NSError(domain: "SignalingClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }
        
        return answerSdp
    }
}
