import Foundation

/// What a listening process is: Vite, PostgreSQL, an ngrok tunnel, an app.
public struct Framework: Hashable, Sendable {
    public let id: String
    public let name: String
    /// sRGB hex. `nil` means "use the label color" for monochrome brands like Next.js.
    public let color: UInt32?
    public let category: ServerCategory
    public let speaksHTTP: Bool
    /// Scheme for a connection string, such as `postgresql` or `redis`.
    public let urlScheme: String?

    public init(_ id: String, _ name: String, _ color: UInt32?, _ category: ServerCategory = .dev,
                http: Bool = true, scheme: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.category = category
        self.speaksHTTP = http
        self.urlScheme = scheme
    }
}

public extension Framework {
    // JavaScript
    static let vite = Framework("vite", "Vite", 0x8B7CFF)
    static let next = Framework("next", "Next.js", nil)
    static let nuxt = Framework("nuxt", "Nuxt", 0x00DC82)
    static let astro = Framework("astro", "Astro", 0xFF5D01)
    static let remix = Framework("remix", "Remix", 0x3992FF)
    static let reactRouter = Framework("react-router", "React Router", 0xF44250)
    static let svelteKit = Framework("sveltekit", "SvelteKit", 0xFF3E00)
    static let storybook = Framework("storybook", "Storybook", 0xFF4785)
    static let expo = Framework("expo", "Expo", 0x4E5BEF)
    static let metro = Framework("metro", "Metro", 0x61DAFB)
    static let webpack = Framework("webpack", "webpack", 0x8DD6F9)
    static let createReactApp = Framework("cra", "Create React App", 0x61DAFB)
    static let angular = Framework("angular", "Angular", 0xDD0031)
    static let vueCLI = Framework("vue", "Vue CLI", 0x42B883)
    static let parcel = Framework("parcel", "Parcel", 0xE7A93C)
    static let gatsby = Framework("gatsby", "Gatsby", 0x8A4BAF)
    static let docusaurus = Framework("docusaurus", "Docusaurus", 0x3ECC5F)
    static let vitepress = Framework("vitepress", "VitePress", 0x5C73E7)
    static let eleventy = Framework("eleventy", "Eleventy", 0x9E9E9E)
    static let wrangler = Framework("wrangler", "Wrangler", 0xF38020)
    static let vercel = Framework("vercel", "Vercel Dev", nil)
    static let netlify = Framework("netlify", "Netlify Dev", 0x00C7B7)
    static let firebase = Framework("firebase", "Firebase Emulators", 0xFFA000)
    static let convex = Framework("convex", "Convex", 0xF3B01C)
    static let prismaStudio = Framework("prisma", "Prisma Studio", 0x5A67D8)
    static let drizzleStudio = Framework("drizzle", "Drizzle Studio", 0xA3C93A)
    static let nest = Framework("nest", "NestJS", 0xE0234E)
    static let staticServer = Framework("static", "Static Server", 0x9CA3AF)
    static let bun = Framework("bun", "Bun", 0xE8C79A)
    static let deno = Framework("deno", "Deno", nil)
    static let node = Framework("node", "Node.js", 0x5FA04E)

    // Python
    static let django = Framework("django", "Django", 0x44B78B)
    static let flask = Framework("flask", "Flask", 0x3BABC3)
    static let fastAPI = Framework("fastapi", "FastAPI", 0x05998B)
    static let uvicorn = Framework("uvicorn", "Uvicorn", 0x05998B)
    static let gunicorn = Framework("gunicorn", "Gunicorn", 0x499848)
    static let streamlit = Framework("streamlit", "Streamlit", 0xFF4B4B)
    static let gradio = Framework("gradio", "Gradio", 0xF97316)
    static let jupyter = Framework("jupyter", "Jupyter", 0xF37626)
    static let mkdocs = Framework("mkdocs", "MkDocs", 0x526CFE)
    static let pythonHTTP = Framework("python-http", "http.server", 0xFFD43B)
    static let python = Framework("python", "Python", 0x4B8BBE)

    // Other languages
    static let rails = Framework("rails", "Rails", 0xD30001)
    static let jekyll = Framework("jekyll", "Jekyll", 0xCC0000)
    static let ruby = Framework("ruby", "Ruby", 0xCC342D)
    static let laravel = Framework("laravel", "Laravel", 0xFF2D20)
    static let php = Framework("php", "PHP", 0x777BB4)
    static let hugo = Framework("hugo", "Hugo", 0xFF4088)
    static let go = Framework("go", "Go", 0x00ADD8)
    static let rust = Framework("rust", "Rust", 0xDE6A3B)
    static let trunk = Framework("trunk", "Trunk", 0xDE6A3B)
    static let phoenix = Framework("phoenix", "Phoenix", 0xFD4F00)
    static let elixir = Framework("elixir", "Elixir", 0x9B6BCF)
    static let spring = Framework("spring", "Spring Boot", 0x6DB33F)
    static let java = Framework("java", "Java", 0xE76F00)
    static let dotnet = Framework("dotnet", ".NET", 0x7B5CE6)
    static let swift = Framework("swift", "Swift", 0xF05138)

    // Databases
    static let postgres = Framework("postgres", "PostgreSQL", 0x4F8BC9, .database, http: false, scheme: "postgresql")
    static let mysql = Framework("mysql", "MySQL", 0xF29111, .database, http: false, scheme: "mysql")
    static let mariadb = Framework("mariadb", "MariaDB", 0xC49A6C, .database, http: false, scheme: "mysql")
    static let mongo = Framework("mongo", "MongoDB", 0x47A248, .database, http: false, scheme: "mongodb")
    static let redis = Framework("redis", "Redis", 0xDC382D, .database, http: false, scheme: "redis")
    static let valkey = Framework("valkey", "Valkey", 0x6983FF, .database, http: false, scheme: "redis")
    static let memcached = Framework("memcached", "Memcached", 0x7DB04B, .database, http: false)
    static let clickhouse = Framework("clickhouse", "ClickHouse", 0xFFCC01, .database)
    static let elasticsearch = Framework("elasticsearch", "Elasticsearch", 0xFEC514, .database)
    static let opensearch = Framework("opensearch", "OpenSearch", 0x005EB8, .database)
    static let meilisearch = Framework("meilisearch", "Meilisearch", 0xFF5CAA, .database)
    static let typesense = Framework("typesense", "Typesense", 0xD52B6C, .database)
    static let qdrant = Framework("qdrant", "Qdrant", 0xDC244C, .database)
    static let minio = Framework("minio", "MinIO", 0xC72E49, .database)
    static let influx = Framework("influx", "InfluxDB", 0x9394FF, .database)
    static let cockroach = Framework("cockroach", "CockroachDB", 0x6933FF, .database, http: false, scheme: "postgresql")
    static let surreal = Framework("surreal", "SurrealDB", 0xFF00A0, .database)
    static let etcd = Framework("etcd", "etcd", 0x419EDA, .database, http: false)

    // Services
    static let docker = Framework("docker", "Docker", 0x2496ED, .service)
    static let orbstack = Framework("orbstack", "OrbStack", 0x9B6BFF, .service)
    static let ngrok = Framework("ngrok", "ngrok", 0x3D6BFF, .service)
    static let cloudflared = Framework("cloudflared", "Cloudflare Tunnel", 0xF38020, .service)
    static let nats = Framework("nats", "NATS", 0x27AAE1, .service, http: false, scheme: "nats")
    static let rabbitmq = Framework("rabbitmq", "RabbitMQ", 0xFF6600, .service, http: false, scheme: "amqp")
    static let ollama = Framework("ollama", "Ollama", nil, .service)
    static let lmStudio = Framework("lmstudio", "LM Studio", 0x6366F1, .service)
    static let localstack = Framework("localstack", "LocalStack", 0x3F51C7, .service)
    static let mailpit = Framework("mailpit", "Mailpit", 0x2EC4B6, .service)

    // Everything else
    static let app = Framework("app", "App", 0x8E8E93, .other, http: false)
    static let tool = Framework("tool", "Process", 0x8E8E93, .other, http: false)
}
