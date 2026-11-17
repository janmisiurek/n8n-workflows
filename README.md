# AI & Workflow Automation Portfolio

I build workflow automations and tools that connect business data, language models and external services. My projects cover sales processes, AI-assisted work management, and content production and analysis.

I use n8n, REST APIs, Python and JavaScript, together with Codex and Cursor. My work with AI agents includes reusable skills, project instructions, task handoffs, MCP integrations and validation through tests and practical checks.

## Sales automation

### [Salesforce Offer Assistant](./salesforce%20offer%20assistant/)

A demonstration built in Salesforce Developer Edition using fictional business records. The workflow reads an opportunity and a service catalog, uses OpenAI to propose a scope, calculates prices in code, and lets a person revise or approve the offer. Approval saves a PDF in Salesforce.

The integration has been tested with real model responses, missing input, revisions and simultaneous approval requests. Concurrent approvals produced a single document version.

**Technologies** · n8n, Salesforce, OpenAI API, JavaScript, Apex, OAuth.

### [Coldmail Automation](./coldmail%20automation/)

Google Maps lead discovery, website scraping, email extraction and Google Sheets storage. A three-step outreach sequence uses language models to personalize messages, while IMAP monitoring updates reply status and notifies the person managing the process.

**Technologies** · n8n, JavaScript, Google Sheets, SMTP/IMAP, OpenRouter, Azure OpenAI.

## AI agent integrations

### [n8n + External AI Agents](./n8n%20+%20cursor%20ai/)

Three connected workflows expose n8n tools through MCP, export workflows to local JSON files, and synchronize file changes back through the n8n API. The integration supports workflow development with an AI agent in Cursor.

**Technologies** · n8n, MCP, REST API, JSON, file monitoring.

## Additional projects

### Codex + Obsidian project workspace

A local system for planning and carrying out work across several projects. Reusable skills and AGENTS.md instructions define task scope, agent roles, handoffs and acceptance criteria. A Python CLI maintains plans, work history and project records.

I use the workspace in ongoing project work and refine its procedures based on observed failures and review results.

**Technologies** · Codex, AI agents, skills, Python, CLI, Markdown, Obsidian.

### Video production and analytics workflow

A workflow covering research, scripts, AI voiceover, animatics, rendering, publication and performance measurements. A shared local dashboard brings together YouTube and Facebook materials, analyses and timestamped readings.

Project skills guide production stages and review. Rendering utilities reuse completed shots when their inputs match, reducing repeated rendering during revisions.

**Technologies** · Codex, Python, SQLite, JavaScript, Blender, FFmpeg, ElevenLabs.

### SunApp

An ongoing application project developed with AI-assisted planning, implementation and QA. My work includes translating user feedback into scoped changes, investigating failures, coordinating testing and preparing iPhone and Apple Watch builds. Physical-device acceptance is tracked for each change.

**Technologies** · Codex, Flutter, Dart, Swift, watchOS, HealthKit, Xcode.

### [YouTube Screenshots API](https://github.com/janmisiurek/yt-screenshots-api)

A Python service that extracts frames at requested timestamps, with optional Azure Blob Storage and image descriptions generated through Azure OpenAI.

**Technologies** · Python, FastAPI, Playwright, Azure Blob Storage, Azure OpenAI.

## More n8n workflows

### [FAL.ai Telegram Image Generator](./fal%20bot/)

A Telegram bot for image generation through FAL.ai, including generation parameters, LoRA configuration and asynchronous job polling.

**Technologies** · n8n, JavaScript, Telegram Bot API, FAL.ai.

### [YouTube Podcast Processing](./youtube%20podcast%20processing/)

An MVP that monitors YouTube channels, retrieves transcripts and produces structured summaries for an ElizaOS agent. PostgreSQL tracks processed videos.

**Technologies** · n8n, JavaScript, OpenAI API, PostgreSQL, ElizaOS.
