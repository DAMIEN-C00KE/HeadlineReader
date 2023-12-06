# HeadlineReader
Scrapes headlines from the inputted URLs, and prints them to an SQLite database. (# Work in progress)
- Current emphasis is on scraping financial news data. Can be easily customised to other use-case

Before running, ensure you've installed the required packages via the Julia REPL:

- Run import Pkg, then install below packages:

- Pkg.add("HTTP")
- Pkg.add("Gumbo")
- Pkg.add("Cascadia")
- Pkg.add("SQLite")
- Pkg.add("Dates")
- Pkg.add("JSON")
- Pkg.add("CSV")
- Pkg.add("DataFrames")
- Pkg.add("Plots")

- Download Loughran-Mcdonald financial dictionary from: https://sraf.nd.edu/loughranmcdonald-master-dictionary/

TODO:
- Create framework for identifying recurring headlines
- Implement NLP for more robust identification of sentiment
- Aggregate sentiment on a timeframe basis (daily, weekly, monthly, quarterly)
- Add a matrix graph to track sentiment over chosen timeframe
- Plot sentiment next to price chart to  visualise price/sentiment correlation
