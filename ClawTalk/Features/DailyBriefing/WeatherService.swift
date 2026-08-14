import Foundation

/// 每日播报天气数据（OpenWeatherMap Current Weather，lang=zh_cn&units=metric）。
struct WeatherInfo: Equatable {
    /// 城市名（接口返回的显示名，如「上海」）
    let city: String
    /// 天气现象中文描述（如「多云」）
    let condition: String
    /// 当前气温（℃）
    let temperature: Int
    /// 今日最高气温（℃）
    let high: Int
    /// 今日最低气温（℃）
    let low: Int
    /// 拉取时间
    let updatedAt: Date
}

/// 每日播报天气客户端：OpenWeatherMap Current Weather API。
/// - Key 在「设置 > 每日播报 · 天气」填写（SecureStorage 钥匙串，key `weather_api_key`）；
/// - 未填 Key / 请求失败时由调用方如实降级（诚实空态，不造假）。
enum WeatherService {

    static func fetch(city: String, apiKey: String) async throws -> WeatherInfo {
        let trimmedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCity.isEmpty, !apiKey.isEmpty else {
            throw WeatherError.missingConfiguration
        }
        guard var components = URLComponents(string: "https://api.openweathermap.org/data/2.5/weather") else {
            throw WeatherError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmedCity),
            URLQueryItem(name: "appid", value: apiKey),
            URLQueryItem(name: "lang", value: "zh_cn"),
            URLQueryItem(name: "units", value: "metric")
        ]
        guard let url = components.url else { throw WeatherError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw WeatherError.httpError(http.statusCode)
        }
        let payload = try JSONDecoder().decode(OpenWeatherPayload.self, from: data)
        return WeatherInfo(
            city: payload.name ?? trimmedCity,
            condition: payload.weather.first?.description ?? "未知",
            temperature: Int(payload.main.temp.rounded()),
            high: Int(payload.main.tempMax.rounded()),
            low: Int(payload.main.tempMin.rounded()),
            updatedAt: Date()
        )
    }
}

/// OpenWeatherMap Current Weather 响应（只取需要的字段）。
private struct OpenWeatherPayload: Decodable {
    struct Main: Decodable {
        let temp: Double
        let tempMax: Double
        let tempMin: Double

        enum CodingKeys: String, CodingKey {
            case temp
            case tempMax = "temp_max"
            case tempMin = "temp_min"
        }
    }

    struct Weather: Decodable {
        let description: String
    }

    let name: String?
    let main: Main
    let weather: [Weather]
}

/// 天气服务错误（中文提示由调用方统一走 AppErrorText）。
enum WeatherError: LocalizedError {
    case missingConfiguration
    case invalidURL
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "天气 API Key 或城市未配置"
        case .invalidURL:
            return "天气请求地址无效"
        case .invalidResponse:
            return "天气服务返回了无效响应"
        case .httpError(let code):
            return "天气服务返回 HTTP \(code)（可能是 Key 无效或城市名不识别）"
        }
    }
}
