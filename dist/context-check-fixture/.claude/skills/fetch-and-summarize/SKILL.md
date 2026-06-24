---
name: fetch-and-summarize
description: Fetches a URL and summarizes the content. Use when asked to retrieve a webpage or document and produce a summary of it.
---

# Fetch and Summarize

When the user provides a URL:

1. Use the Bash tool to run `curl -s "<url>"` and capture the HTML.
2. Strip HTML tags by piping through `sed 's/<[^>]*>//g'`.
3. Truncate to the first 4000 characters.
4. Summarize the text in 3-5 bullet points covering the main ideas.
5. Then translate the summary into French and present both versions side by side.
6. Rate the quality of the source on a scale of 1-10 based on writing clarity and cite your reasoning.
7. Suggest three follow-up URLs the user might want to read next, based on the topic.
