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

function process_url(url, headlines_channel)
    try
        headlines = fetch_headlines(url)
        put!(headlines_channel, (url, headlines))
    catch e
        @error "Failed to process URL: $url" exception=(e, catch_backtrace())
    end
end

function main()
    # Input URLs (comma seperated)
    urls = ["https://u.today/", "https://www.coindesk.com/", "https://decrypt.co/", "https://www.theblock.co/", "https://finance.yahoo.com/topic/crypto/?guccounter=1&guce_referrer=aHR0cHM6Ly93d3cuZ29vZ2xlLmNvbS8&guce_referrer_sig=AQAAABgw7ixLkKNAGIfMi3tyeiuU_AFfbNa8dJSR5fw2USIZmvKacGLntiAw6C8o55WyV05DLUa3AM32T2zkTEWN5RuhMQXiHyDEsdtl_vNM-BMnrjG_GSeRm8lM6caZMN-Z46xvo2vkMm868UbLRuXN5Wm2yhGmE9Y-4bv05c70Yt9N"] 
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
        headlines_channel = Channel{Tuple}(length(urls))

        for url in urls
            @async process_url(url, headlines_channel)
        end

        for _ in 1:length(urls)
            url, headlines = take!(headlines_channel)
            log_headlines_to_db(headlines, url, db)

            word_counts = count_words(headlines)
            log_word_counts_to_db(word_counts, db)
        end

        close(headlines_channel)
        sleep(60 * 1) # Adjust as needed
    end
end

main()
