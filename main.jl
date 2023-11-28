# Import packages required
using HTTP, Gumbo, Cascadia, SQLite, Dates

# Web request
function fetch_headlines(url)
    response = HTTP.get(url)
    parsed_html = parsehtml(String(response.body))

    headlines = []
    for tag in ["h1", "h2", "h3"]
        elements = eachmatch(Selector(tag), parsed_html.root)
        for elem in elements
            push!(headlines, Gumbo.text(elem))
        end
    end

    return headlines
end

# Log headlines to SQLite database
function log_headlines_to_db(headlines, url, db)
    for headline in headlines
        SQLite.execute(db, "INSERT INTO headlines (date, url, headline) VALUES (?, ?, ?)",
                        (Dates.now(), url, headline))
    end
end

function main()
    urls = [] # Input URLs (comma seperated)
    db = SQLite.DB("headlines.db")

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS headlines (
            id INTEGER PRIMARY KEY,
            date TEXT,
            url TEXT,
            headline TEXT
        )
    """)

    while true
        for url in urls
            headlines = fetch_headlines(url)
            log_headlines_to_db(headlines, url, db)
        end

        sleep(60 * 5) # Adjust as needed
    end
end

main()
