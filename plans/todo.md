# Muesli - Future Enhancements

Track future work, features, and improvements here.

---

## Enhancements

**[Enhancement]** [High] Add vocabulary prompting for specialized terms
- Description: Allow users to specify common terms/proper nouns for better transcription accuracy
- Notes: OpenAI's prompting guide shows vocabulary conditioning is highly effective for proper nouns
- Implementation considerations (needs design):
  - Tokenization lifecycle: when to tokenize (app launch vs recording start), where to cache
  - Error handling for tokenization failures (WhisperKit tokenizer may be nil)
  - User preference UI in Preferences > Transcription section
  - Default vocabulary pre-populated with NVIDIA terms (NeMo RL, CUDA, TensorRT, H100, Blackwell, etc.)
  - Token limit: WhisperKit allows ~224 tokens (~50-100 words)
- API: `DecodingOptions.promptTokens` with glossary format ("Glossary: term1, term2, ...")
- Related: TranscriptionService.swift, PreferencesManager.swift, WhisperKit DecodingOptions
- Effort: ~3-4 hours (includes proper tokenization lifecycle design)
- Rationale: Highest-impact transcription quality improvement per OpenAI documentation
