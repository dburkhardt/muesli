# Muesli Website

This directory contains the GitHub Pages website for Muesli.

## Structure

```
docs/
├── index.html          # Main landing page
├── download.html       # Download and installation instructions
└── assets/
    ├── logo.svg        # App logo (SVG)
    ├── screenshot.svg  # App screenshot placeholder
    └── style.css       # Stylesheet
```

## Local Development

To preview the site locally:

```bash
cd docs
python3 -m http.server 8000
```

Then open http://localhost:8000 in your browser.

## Deployment

The site is automatically deployed to GitHub Pages from the `docs/` folder on the main branch.

Configure in repository Settings → Pages:
- Source: Deploy from a branch
- Branch: main
- Folder: /docs

## Analytics

Download statistics are updated hourly by the GitHub Actions workflow `.github/workflows/update-download-stats.yml`. The workflow:

1. Fetches release data from GitHub API
2. Calculates total downloads across all releases
3. Stores stats as GitHub Actions artifacts (retained for 90 days)
4. No user tracking or personal data collection

The download count on the homepage is fetched directly from the GitHub Releases API client-side.

## Design

The site follows a minimal, "Granola-inspired" design:
- Clean white background with generous whitespace
- SF Pro font stack (system fonts)
- Primary accent color: #0066cc (blue)
- Mobile-responsive layout
- No JavaScript frameworks, pure HTML/CSS

## Privacy

- No cookies
- No third-party analytics
- No user tracking
- Only aggregate download counts from GitHub API
