# HeadlineReader
Scrapes headlines from the inputted URLs, and prints them to an SQLite database. (# Work in progress)

Before running, ensure you've installed the required packages via the Julia REPL:
Guide:
- Use import Pkg
then install below packages:
- Pkg.add("HTTP")
- Pkg.add("Gumbo")
- Pkg.add("Cascadia")
- Pkg.add("SQLite")
- Pkg.add("Dates")
- Pkg.add("JSON")

TODO:
- Create tests to appropriately handle errors
- Create framework for identifying recurring headlines
- Implement NLP and create a sentimental analysis framework
