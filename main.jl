# Import packages required
using HTTP, Gumbo, Cascadia, SQLite, Dates, JSON, CSV, DataFrames

# Load config from JSON file
function load_config(config_path)
    open(config_path, "r") do file
        return JSON.parse(file)
    end
end

# Load financial dictionary (Loughran-Mcdonald = default)
function load_financial_dictionary(dict_path)
    df = CSV.read(dict_path, DataFrame)
    positive_words = Set{String}()
    negative_words = Set{String}()

    for row in eachrow(df)
        # If using a different dictionary, ensure you input the correct names of columns,
        # This assumes you're using the Loughran-Mcdonald dictionary
        word = lowercase(row[:Word])
        
            if row[:Positive] == 2009
                push!(positive_words, word)
            end
            if row[:Negative] == 2009
                push!(negative_words, word)
        end
    end

    return positive_words, negative_words
end

config = load_config("config.json")

# Using configuration
sleep_interval = config["sleep_interval"]
urls = config["urls"]
stop_words = Set(config["stop_words"])
financial_dict_path = config["financial_dict_path"]

# Load words from dictionary
positive_words, negative_words = load_financial_dictionary(financial_dict_path)

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
        processed_text, sentiment = process_headline(headline)
        datetime_text = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")

        SQLite.execute(db, "INSERT INTO headlines (date, url, headline, sentiment) VALUES (?, ?, ?, ?)",
                        (datetime_text, url, processed_text, sentiment))
    end
end

# Count words
function count_words(headlines)
    word_counts = Dict{String, Int}()
    for headline in headlines
        processed_text, _ = process_headline(headline)
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

# Function for basic sentiment analysis
function analyze_sentiment(text)
    positive_count = 0
    negative_count = 0

    words = split(lowercase(text), ' ')
    for word in words
        if word in positive_words # These sets should contain lower case words
            positive_count += 1
        elseif word in negative_words
            negative_count += 1
        end
    end

    if positive_count > negative_count
        return "Positive"
    elseif negative_count > positive_count
        return "Negative"
    else
        return "Neutral"
    end
end

# Function to process each headline
function process_headline(headline)
    sentiment = analyze_sentiment(headline)
    return headline, sentiment
end

function process_url(url, headlines_channel, use_chrome_agent)
    try
        headlines = fetch_headlines(url, use_chrome_agent)
        put!(headlines_channel, (url, headlines))
    catch e
        @error "Failed to process URL: $url" exception=(e, catch_backtrace())
    end
end

function update_sentiment_count(db, sentiment)
    # This statement inserts a new record or updates the count if the sentiment already exists
    SQLite.execute(db, """
        INSERT INTO sentiment_counts (sentiment, count)
        VALUES (?, 1)
        ON CONFLICT(sentiment)
        DO UPDATE SET count = count + 1
    """, (sentiment,))
end


function main()
    db = SQLite.DB("headlines.db")

    # Create tables if they don't exist
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS headlines (
            id INTEGER PRIMARY KEY,
            date TEXT,
            url TEXT,
            headline TEXT,
            sentiment TEXT
        )
    """)

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS word_counts (
            id INTEGER PRIMARY KEY,
            word TEXT,
            count INTEGER
        )
    """)

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS sentiment_counts (
            id INTEGER PRIMARY KEY,
            sentiment TEXT UNIQUE,
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

            for headline in headlines
                _, sentiment = process_headline(headline)
                update_sentiment_count(db, sentiment)
            end
        end

        close(headlines_channel)
        sleep(sleep_interval) # Adjust in config file (seconds)
    end
end

main()
