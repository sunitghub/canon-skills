;; This buffer is for text that is not saved, and for Lisp evaluation.
;; To create a file, visit it with ‘C-x C-f’ and enter text in its buffer.

1. Create a skill that slugifies entries in seven steps: lowercase > hypenate whitespace > strip characters > collapse > trim
2. Run slugify-noevals against "what's the take?". Output just the result.
3. Try against with ""This is smokin'" . Note the ' since the skill's allowed-character set (a-z0-9-') keeps it; not URL-safe (apostrophes need encoding in a URL path segment).
4. Write evals for this examples/slugify/skills/slugify-noevals under evals sub-folder. 2-3 cases. Include a happy path, plus an apostrophe at end edge case.
