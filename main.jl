# Import packages required
using HTTP, Gumbo, Cascadia, SQLite, Dates, JSON

# Load config from JSON file
function load_config(config_path)
    open(config_path, "r") do file
        return JSON.parse(file)
    end
end

config = load_config("config.json")

# Using configuration
sleep_interval = config["sleep_interval"]
urls = config["urls"]
stop_words = Set(config["stop_words"])

# Define User-Agent strings
chrome_user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.51 Safari/537.36"
firefox_user_agent = "Mozilla/5.0 (Windows NT 10.0; rv:86.0) Gecko/20100101 Firefox/86.0"

# Function to fetch headlines
function fetch_headlines(url, use_chrome_agent)
    headers = [
        "User-Agent" => use_chrome_agent ? chrome_user_agent : firefox_user_agent
    ]

    response = HTTP.get(url, headers)
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

function process_url(url, headlines_channel, use_chrome_agent)
    try
        headlines = fetch_headlines(url, use_chrome_agent)
        put!(headlines_channel, (url, headlines))
    catch e
        @error "Failed to process URL: $url" exception=(e, catch_backtrace())
    end
end

function main()
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
        use_chrome_agent = true

        headlines_channel = Channel{Tuple}(length(urls))

        for url in urls
            @async process_url(url, headlines_channel, use_chrome_agent)
            use_chrome_agent = !use_chrome_agent # Toggle between Chrome and Firefox
        end

        for _ in 1:length(urls)
            url, headlines = take!(headlines_channel)
            log_headlines_to_db(headlines, url, db)

            word_counts = count_words(headlines)
            log_word_counts_to_db(word_counts, db)

        end

        close(headlines_channel)
        sleep(sleep_interval) # Adjust in config file (seconds)
    end
end

main()
