# HeadlineReader
Scrapes headlines from the inputted URLs, and prints them to an SQLite database. (# Work in progress)
- Current emphasis is on scraping financial news data. Can be easily customised to other use-case

#### Instructions
1) After cloning repo, proceed to directory where you have stored the repo, and in the Julia REPL:
2) Go to pkg mode: julia> ]
3) Activate a new environment: (CurrentVersion) pkg> activate .
4) Then instantiate to download the dependancies: (HeadlineReader) pkg> instantiate

- Download Loughran-Mcdonald financial dictionary from: https://sraf.nd.edu/loughranmcdonald-master-dictionary/

#### TODO:
- Create framework for identifying recurring headlines
- Implement NLP for more robust identification of sentiment
- Aggregate sentiment on a timeframe basis (daily, weekly, monthly, quarterly)
- Add a matrix graph to track sentiment over chosen timeframe
- Plot sentiment next to price chart to  visualise price/sentiment correlation
