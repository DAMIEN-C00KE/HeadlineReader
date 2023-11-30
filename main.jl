# Import packages required
using HTTP, Gumbo, Cascadia, SQLite, Dates

# Define stop words
stop_words = Set(["the", "is", "at", "of", "and", "in", "to", "a", "crypto", "cryptocurrency", "news", "with", "as",
"for", "s", "u", "1", "on", "that", "this", "its", "it"])

# Function to fetch headlines
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

# Log headlines to database
function log_headlines_to_db(headlines, url, db)
    for headline in headlines
        # Format the current date-time as text
        datetime_text = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")

        SQLite.execute(db, "INSERT INTO headlines (date, url, headline) VALUES (?, ?, ?)",
                        (datetime_text, url, headline))
    end
end

# Count words
function count_words(headlines)
    word_counts = Dict{String, Int}()
    for headline in headlines
        words = split(lowercase(headline), r"\W+")
        for word in words
            if word ∉ stop_words && word != ""
                word_counts[word] = get(word_counts, word, 0) + 1
            end
        end
    end
    return word_counts
end

# Log word counts to database
function log_word_counts_to_db(word_counts, db)
    for (word, count) in word_counts
        SQLite.execute(db, "INSERT into word_counts (word, count) VALUES (?, ?)", 
                        (word, count))
    end
end

function main()
    urls = ["example_url.com", "example_url2.com"] # Input URLs (comma seperated)
    db = SQLite.DB("headlines.db")

    # Create tables if they don't exist
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS headlines (
            id INTEGER PRIMARY KEY,
            date TEXT,
            url TEXT,
            headline TEXT
        )
    """)

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS word_counts (
            id INTEGER PRIMARY KEY,
            word TEXT,
            count INTEGER
        )
    """)

    while true
        for url in urls
            headlines = fetch_headlines(url)
            log_headlines_to_db(headlines, url, db)

            word_counts = count_words(headlines)
            log_word_counts_to_db(word_counts, db)
        end

        sleep(60 * 5) # Adjust as needed
    end
end

main()
