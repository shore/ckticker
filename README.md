# ckticker

The ckticker script tracks trailing stops for stock closing prices.  Data is fetched from Yahoo! Finance, highest (recent) close price is stored locally, and trailing stop ratios can be set for individual stocks and as a global default.  Configuration is via a simple yaml document which the script updates at each run with new highs, keeping a backup of the previous data as well.  It is intended to be run from cron and generates an email message listing all stocks which have dropped by more than their stop ratio, separated by whether they are stopped or unstopped.

### Sample cron job:
`45 13 * * 1-5   /home/user/ckticker.pl >/dev/null`
