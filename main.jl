# Import packages required
using HTTP, Gumbo, Cascadia, SQLite, Dates, JSON, CSV, DataFrames, Plots, StatsBase

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

# Function to get headlines for a specific timeframe
function get_headlines_for_timeframe(db, start_date, end_date)
    return DBInterface.execute(db, "SELECT headline FROM headlines WHERE date BETWEEN ? AND ?", (start_date, end_date)) |> DataFrame
end

# Function to aggregate data for a given timeframe
function aggregate_data(db, start_date, end_date)
    # Fetch headlines for the given timeframe
    timeframe_headlines = get_headlines_for_timeframe(db, start_date, end_date)

    # Aggregate word counts
    timeframe_word_counts = count_words(timeframe_headlines.headline)

    # Aggregate sentiment counts
    timeframe_sentiments = [analyze_sentiment(headline) for headline in timeframe_headlines.headline]
    timeframe_sentiments_counts = countmap(timeframe_sentiments)

    return timeframe_word_counts, timeframe_sentiments_counts
end

# Perform daily aggregation
function aggregate_daily_data(db)
    today = Dates.today()
    yesterday = today - Dates.Day(1)
    return aggregate_data(db, yesterday, today)
end

# Perform weekly aggregation
function aggregate_weekly_data(db)
    today = Dates.today()
    last_week = today - Dates.Day(7)
    return aggregate_data(db, last_week, today)
end

# Perform monthly aggregation
function aggregate_monthly_data(db)
    today = Dates.today()
    last_month = today - Dates.Month(1)
    return aggregate_data(db, last_month, today)
end

# Perform quarterly aggregation
function aggregate_quarterly_data(db)
    today = Dates.today()
    last_quarter = today - Dates.Month(3)
    return aggregate_data(db, last_quarter, today)
end

function fetch_headlines(url, use_chrome_agent)
    try
        headers = [
            "User-Agent" => use_chrome_agent ? chrome_user_agent : firefox_user_agent
        ]

        response = HTTP.get(url, headers)
        parsed_html = parsehtml(String(response.body))

        headlines_with_dates = []
        for tag in ["h1", "h2", "h3"]
            headline_elements = eachmatch(Selector(tag), parsed_html.root)
            for headline_elem in headline_elements
                headline_text = Gumbo.text(headline_elem)

                # Try to find the date element related to this specific headline
                parent_elem = headline_elem.parent
                date_elem = parent_elem !== nothing ? match(Selector(raw"body > div.page-container.container > div.main-aside-container > main > div.news > div.news__list > a:nth-child(1) > div.news__item-time-wrapper > div"), parent_elem) : nothing

                # Check if date_elem is an actual element before calling Gumbo.text
                headline_date = (date_elem isa Gumbo.HTMLNode) ? Gumbo.text(date_elem) : "Unknown Date"

                push!(headlines_with_dates, (headline_date, headline_text))
            end
        end

        return headlines_with_dates
    catch e
        @error "Failed to fetch headlines from URL: $url" e
        return [] # Return empty array on error
    end
end

# Log headlines to database
function log_headlines_to_db(headlines_with_dates, url, db)
    try
        for headline_tuple in headlines_with_dates
            # Process the entire tuple for sentiment analysis
            processed_tuple, sentiment = process_headline(headline_tuple)

            # Extract date and processed headline text from the tuple
            date, processed_text = processed_tuple

            # Insert data into the database
            SQLite.execute(db, "INSERT INTO headlines (date, url, headline, sentiment) VALUES (?, ?, ?, ?)",
                            (date, url, processed_text, sentiment))
        end
    catch e
        @error "Failed to log headlines to database for URL: $url" e
    end
end


# Count words
function count_words(headlines_with_dates)
    try
        word_counts = Dict{String, Int}()
        for (date, headline) in headlines_with_dates
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
function analyze_sentiment(headline_tuple)
    # Ensure headline_tuple is indeed a tuple and has two elements
    if typeof(headline_tuple) == Tuple && length(headline_tuple) == 2
        text = headline_tuple[2]  # Extract the headline text
        positive_count = 0
        negative_count = 0

        words = split(lowercase(text), r"\W+")
        for word in words
            if word in positive_words
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
    else
        @warn "analyze_sentiment received invalid input"
        return "Unknown"
    end
end

# Function to process each headline
function process_headline(headline_tuple)
    if typeof(headline_tuple) == Tuple && length(headline_tuple) == 2
        sentiment = analyze_sentiment(headline_tuple)
        return (headline_tuple, sentiment)
    else
        @warn "process_headline received invalid input"
        return (headline_tuple, "Unknown")
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

function log_aggregated_word_counts(db, word_counts, timeframe)
    for (word, count) in word_counts
        existing_record = DBInterface.execute(db, "SELECT count FROM aggregated_word_counts WHERE word = ? AND timeframe = ?", (word, timeframe)) |> DataFrame

        if isempty(existing_record)
            SQLite.execute(db, "INSERT INTO aggregated_word_counts (word, count, timeframe) VALUES (?, ?, ?)", (word, count, timeframe))
        else
            new_count = existing_record[1, :count] + count
            SQLite.execute(db, "UPDATE aggregated_word_counts SET count = ? WHERE word = ? AND timeframe = ?", (new_count, word, timeframe))
        end
    end
end

function log_aggregated_sentiment_counts(db, sentiment_counts, timeframe)
    for (sentiment, count) in sentiment_counts
        existing_record = DBInterface.execute(db, "SELECT count FROM aggregated_sentiment_counts WHERE sentiment = ? AND timeframe = ?", (sentiment, timeframe)) |> DataFrame

        if isempty(existing_record)
            SQLite.execute(db, "INSERT INTO aggregated_sentiment_counts (sentiment, count, timeframe) VALUES (?, ?, ?)", (sentiment, count, timeframe))
        else
            new_count = existing_record[1, :count] + count
            SQLite.execute(db, "UPDATE aggregated_sentiment_counts SET count = ? WHERE sentiment = ? AND timeframe = ?", (new_count, sentiment, timeframe))
        end
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

        SQLite.execute(db, """
            CREATE TABLE IF NOT EXISTS aggregated_word_counts (
                id INTEGER PRIMARY KEY,
                word TEXT,
                count INTEGER,
                timeframe TEXT
            )
        """)

        SQLite.execute(db, """
            CREATE TABLE IF NOT EXISTS aggregated_sentiment_counts (
                id INTEGER PRIMARY KEY,
                sentiment TEXT,
                count INTEGER,
                timeframe TEXT
            )
        """)

        last_daily_aggregation_date = nothing
        last_weekly_aggregation_date = nothing
        last_monthly_aggregation_date = nothing
        last_quarterly_aggregation_date = nothing

        while true
            current_date = Dates.today()

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

            # Daily aggregation
            @info "Checking for daily aggregation" current_date=Dates.today() last_daily_aggregation_date=last_daily_aggregation_date
            if last_daily_aggregation_date !== current_date
                daily_word_counts, daily_sentiment_counts = aggregate_daily_data(db)
                log_aggregated_word_counts(db, daily_word_counts, "daily")
                log_aggregated_sentiment_counts(db, daily_sentiment_counts, "daily")
                last_daily_aggregation_date = current_date
                @info "Daily aggregation completed and date updated" last_daily_aggregation_date=last_daily_aggregation_date
            end

            # Weekly aggregation
            @info "Checking for weekly aggregation" current_date=Dates.today() last_weekly_aggregation_date=last_weekly_aggregation_date
            if last_weekly_aggregation_date === nothing || Dates.dayofweek(current_date) == 4
                weekly_word_counts, weekly_sentiment_counts = aggregate_weekly_data(db)
                log_aggregated_word_counts(db, weekly_word_counts, "weekly")
                log_aggregated_sentiment_counts(db, weekly_sentiment_counts, "weekly")
                last_weekly_aggregation_date = current_date
                @info "Weekly aggregation completed and date updated" last_weekly_aggregation_date=last_weekly_aggregation_date
            end

            # Monthly aggregation
            @info "Checking for monthly aggregation" current_date=Dates.today() last_monthly_aggregation_date=last_monthly_aggregation_date
            if last_monthly_aggregation_date === nothing || Dates.day(current_date) == 4
                monthly_word_counts, monthly_sentiment_counts = aggregate_monthly_data(db)
                log_aggregated_word_counts(db, monthly_word_counts, "monthly")
                log_aggregated_sentiment_counts(db, monthly_sentiment_counts, "monthly")
                last_monthly_aggregation_date = current_date
                @info "Monthly aggregation completed and date updated" last_monthly_aggregation_date=last_monthly_aggregation_date
            end

            # Quarterly aggregation
            @info "Checking for quarterly aggregation" current_date=Dates.today() last_quarterly_aggregation_date=last_quarterly_aggregation_date
            if last_quarterly_aggregation_date === nothing || Dates.month(current_date) % 3 == 1 && Dates.day(current_date) == 1
                quarterly_word_counts, quarterly_sentiment_counts = aggregate_quarterly_data(db)
                log_aggregated_word_counts(db, quarterly_word_counts, "quarterly")
                log_aggregated_sentiment_counts(db, quarterly_sentiment_counts, "quarterly")
                last_quarterly_aggregation_date = current_date
                @info "Quarterly aggregation completed and date updated" last_quarterly_aggregation_date=last_quarterly_aggregation_date
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