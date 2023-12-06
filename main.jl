# Import packages required
using HTTP, Gumbo, Cascadia, SQLite, Dates, JSON, CSV, DataFrames, Plots

# Load config from JSON file
function load_config(config_path)
    try
        open(config_path, "r") do file
            return JSON.parse(file)
        end
    catch e
        @error "Failed to load config file: $config_path" exception=(e, catch_backtrace())
        return nothing # or default config
    end
end

# Load financial dictionary (Loughran-Mcdonald = default)
function load_financial_dictionary(dict_path)
    try
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
    catch e
        @error "Failed to load dictionary: $dict_path" exception=(e, catch_backtrace())
        return Set{String}(), Set{String}() # Return empty sets on error
    end
end

config = load_config("config.json")

# Check if config is loaded properly
if config === nothing
    @error "Exiting: Configuration file could not be loaded."
    return
end

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
    try
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
    catch e
        @error "Failed to fetch headlines from URL: $url" exception=(e, catch_backtrace())
        return [] # Return empty array on error
    end
end

# Log headlines to database
function log_headlines_to_db(headlines, url, db)
    try
        for headline in headlines
            # Format the current date-time as text
            processed_text, sentiment = process_headline(headline)
            datetime_text = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")

            SQLite.execute(db, "INSERT INTO headlines (date, url, headline, sentiment) VALUES (?, ?, ?, ?)",
                            (datetime_text, url, processed_text, sentiment))
        end
    catch e
        @error "Failed to log headlines to database for URL: $url" exception(e, catch_backtrace())
    end
end

# Count words
function count_words(headlines)
    try
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
    catch e
        @error "Failed to count words" exception=(e, catch_backtrace())
        return Dict{String, Int}() # Return empty Dict on error
    end
end

# Update word count in the database
function update_word_count(db, word, count)
    existing_count = DBInterface.execute(db, "SELECT count FROM word_counts WHERE word = ?", (word,)) |> DataFrame
    if isempty(existing_count)
        SQLite.execute(db, "INSERT INTO word_counts (word, count) VALUES (?, ?)", (word, count))
    else
        new_count = existing_count[1, :count] + count
        SQLite.execute(db, "UPDATE word_counts SET count = ? WHERE word = ?", (new_count, word))
    end
end

# Log word counts to database with aggregation
function log_word_counts_to_db(word_counts, db)
    try
        for (word, count) in word_counts
            update_word_count(db, word, count)
        end
    catch e
        @error "Failed to log word counts to database" exception=(e, catch_backtrace())
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
    try
        # This statement inserts a new record or updates the count if the sentiment already exists
        SQLite.execute(db, """
            INSERT INTO sentiment_counts (sentiment, count)
            VALUES (?, 1)
            ON CONFLICT(sentiment)
            DO UPDATE SET count = count + 1
        """, (sentiment,))
    catch e
        @error "Failed to update sentiment count in database" exception=(e, catch_backtrace())
    end
end

# Function to plot the top 20 most counted words
function plot_top_words(db_path)
    try
        db = SQLite.DB(db_path)
        df = DBInterface.execute(db, "SELECT word, count FROM word_counts ORDER BY count DESC LIMIT 10") |> DataFrame

        # Ensure the DataFrame is not empty
        if isempty(df)
            @error "DataFrame is empty. No data to plot."
            return
        end

        bar(df.word, df.count, title="Top 20 Words", xlabel="Words", ylabel="Count", legend=false, xrotation=45, size=(800,600))
        savefig("top_words.png") # Saves plot to a file
    catch e
        @error "An error occurred in plot_top_words function" exception=(e, catch_backtrace())
    end
end

# Function to plot sentiment counts
function plot_sentiment_counts(db_path)
    try
        db = SQLite.DB(db_path)
        df = DBInterface.execute(db, "SELECT sentiment, count FROM sentiment_counts") |> DataFrame

        if isempty(df)
            @error "DataFrame is empty. No data to plot."
            return
        end

        pie(df.sentiment, df.count, title="Sentiment Counts", legend=:outerright)
        savefig("sentiment_counts.png")
    catch e 
        @error "An error occurred in plot_sentiment_counts function" exception=(e, catch_backtrace())
    end
end


function main()
    try
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

            plot_top_words("headlines.db")
            plot_sentiment_counts("headlines.db")

            close(headlines_channel)
            sleep(sleep_interval) # Adjust in config file (seconds)
        end
    catch e
        @error "Unexpected error in main function" exception=(e, catch_backtrace())
    end
end

main()
