import Foundation

/// Web search tool stub — real implementation requires a search API key
struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web for current information, news, facts, or anything that requires up-to-date knowledge. Returns a summary of search results."

    var parameters: JSONSchema? {
        .object(
            description: "Web search parameters",
            properties: [
                "query": .string(description: "The search query to look up"),
                "num_results": .integer(description: "Number of results to return (default: 3, max: 10)")
            ],
            required: ["query"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let query = arguments["query"]?.stringValue else {
            throw ToolError.missingArgument("query")
        }

        // Clamp to Brave's documented 1–10 range
        let numResults = min(max(arguments["num_results"]?.intValue ?? 3, 1), 10)

        let apiKey = KeychainStore.shared.string(forKey: "search_api_key")
        if let apiKey = apiKey, !apiKey.isEmpty {
            return try await performRealSearch(query: query, numResults: numResults, apiKey: apiKey)
        } else {
            return searchUnavailableMessage(query: query)
        }
    }

    private func performRealSearch(query: String, numResults: Int, apiKey: String) async throws -> String {
        // Build the query string with URLComponents so reserved characters
        // (&, +, =, …) in the query are escaped correctly — .urlQueryAllowed
        // permits them and would corrupt the request.
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(numResults)),
        ]
        guard let url = components?.url else {
            throw ToolError.executionFailed("Invalid search URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ToolError.executionFailed("Search API returned an error")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let webResults = json["web"] as? [String: Any],
              let results = webResults["results"] as? [[String: Any]] else {
            throw ToolError.executionFailed("Failed to parse search results")
        }

        var output = "Search results for '\(query)':\n\n"
        for (i, result) in results.prefix(numResults).enumerated() {
            let title = result["title"] as? String ?? "No title"
            let url = result["url"] as? String ?? ""
            let description = result["description"] as? String ?? "No description"
            output += "\(i + 1). **\(title)**\n   \(url)\n   \(description)\n\n"
        }
        return output
    }

    private func searchUnavailableMessage(query: String) -> String {
        """
        Web search is not configured: no Brave Search API key is set. \
        Tell the user that live results for '\(query)' aren't available \
        and that a search key can be added in Settings.
        """
    }
}
