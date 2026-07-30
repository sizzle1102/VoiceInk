# VoiceInk Inbox Transcription Companion

## Status and intent

This document specifies expected behavior only. It intentionally does not
choose an implementation format, process boundary, transport, packaging model,
or integration mechanism.

The term *companion* means the smallest independently invokable capability
that satisfies these expectations. It may be implemented in any appropriate
form. The implementation plan belongs to a separate session.

## Goal

Allow an automation agent processing a KnowledgeBase inbox to transcribe an
audio attachment without requiring the user to open VoiceInk, press **Start**,
copy a result, or issue a separate transcription command.

The companion must reuse VoiceInk as the canonical source of transcription
configuration and capability. It must not create a second place to configure
models, languages, provider credentials, or local model locations.

The transcript is temporary inbox content. It is not a new archival record and
must not be retained by the companion or added to VoiceInk History.

## User workflow

The user-facing workflow remains:

1. Add an audio attachment to an inbox note.
2. Ask the automation agent to process the inbox.
3. Receive the normal inbox-processing result.

Audio transcription is an internal step of inbox processing. The user does not
run or manage the companion directly during this workflow.

The KnowledgeBase agent remains responsible for:

- detecting supported audio attachments;
- invoking the companion;
- treating the returned transcript as the body of the inbox note;
- routing facts into the appropriate KnowledgeBase notes;
- routing tasks, deadlines, and notifications into Apple Reminders;
- showing the resulting changes;
- requesting approval before deleting the inbox note or its audio attachment.

The companion is responsible only for transcription and its result metadata.

## VoiceInk configuration

VoiceInk must contain exactly one enabled mode named `Inbox`.

For every request, the companion must resolve the current `Inbox` mode from
VoiceInk rather than use a copied or cached configuration. It must use:

- the transcription model selected by the mode;
- the mode's selected language;
- model-specific transcription context such as a Whisper prompt when
  applicable;
- the same deterministic, non-AI cleanup that VoiceInk applies to file
  transcription, including enabled text formatting and configured word
  replacements.

The `Inbox` mode must have AI enhancement disabled. If enhancement is enabled,
the companion must return a configuration error instead of silently applying
or ignoring it.

The companion must support every model that the installed VoiceInk version can
use successfully in its own non-realtime **Transcribe Audio** flow. It must not
maintain a separate provider allowlist.

When the user changes the `Inbox` mode, selected model, language, prompt,
formatting, vocabulary, word replacements, local model installation, or
provider credential in VoiceInk, the next companion invocation must use the
new effective configuration without separate companion setup.

## Invocation and result

The companion must be invokable non-interactively by a local automation agent.
It must accept one supported audio or video file as read-only input and produce
one unambiguously associated result.

The successful result must expose, in a machine-readable form:

- a version for the companion result contract;
- a caller-provided or companion-generated request identifier;
- a success status;
- the transcript;
- the resolved VoiceInk mode name and stable identity, when available;
- the transcription model name and provider;
- the resolved language;
- the media duration;
- whether execution used a local or cloud provider;
- whether AI enhancement was applied, which must be `false`.

The exact serialization, transport, and command surface are implementation
choices. Human-readable diagnostics may accompany the machine-readable result
but must not make it ambiguous.

The companion must never include credentials, credential identifiers, complete
VoiceInk configuration dumps, or unrelated transcription history in its
result.

## Data handling and side effects

The input file is immutable. A successful or failed request must not modify,
move, rename, or delete it.

The companion must not:

- create a VoiceInk History record;
- leave a persistent copy in VoiceInk Recordings;
- alter VoiceInk modes, model selection, language, prompts, vocabulary, word
  replacements, or credentials;
- read or write the clipboard;
- paste or type into another application;
- route content into the KnowledgeBase;
- create Apple Reminders;
- retain the transcript after returning it to the caller.

Temporary files are allowed only when required for processing. They must be
request-scoped and removed after success, failure, cancellation, or timeout.

For a cloud transcription model, audio may be sent only to the provider
selected by the `Inbox` mode. There must be no silent fallback to another
provider, model, or external service.

## Credentials

VoiceInk remains the sole owner of provider credentials. The companion must not
ask the user to enter the same key again, create a second key store, export a
key, or persist a retrieved key.

Credential material must not appear in standard output, standard error,
structured results, logs, crash reports produced by the companion, temporary
files, or test fixtures.

The expectations apply regardless of whether a particular VoiceInk build
stores credentials in UserDefaults, Keychain, or another mechanism. Those
storage details are not a public contract for the companion.

## Isolation from upstream VoiceInk

The default implementation must be external to upstream-managed VoiceInk code.
Routine upstream synchronization, build, signing, and installation must not
require resolving companion-related changes in files owned by upstream.

All assumptions about VoiceInk internals must be isolated behind one
replaceable compatibility boundary. Before transcription begins, the companion
must verify that the installed VoiceInk configuration and runtime capabilities
it depends on are understood. An incompatible or unknown state must produce a
clear failure; it must not produce a best-effort transcript with changed
semantics.

A minimal bridge inside VoiceInk is allowed only as a last resort. Its
implementation must include a written justification showing that the required
behavior cannot be achieved safely by an external companion. If used, the
bridge must be:

- additive and limited to one stable boundary;
- inactive unless explicitly invoked by the companion;
- independent of VoiceInk UI;
- free of changes to the existing recording and transcription behavior;
- free of duplicated provider or credential-management logic;
- covered by compatibility tests;
- small enough that replacement or removal does not affect normal VoiceInk
  operation.

The executor may choose how to satisfy this isolation requirement. This
specification does not mandate a CLI, App Intent, helper application, URL
scheme, local service, IPC mechanism, shared library, or accessibility
automation.

## Failure behavior

The companion must fail before starting transcription when:

- VoiceInk or its required configuration cannot be located;
- there is no enabled mode named `Inbox`;
- more than one enabled mode is named `Inbox`;
- the `Inbox` mode has AI enhancement enabled;
- the selected transcription model is missing, unavailable, or unsupported for
  file transcription;
- a required local model is absent;
- a required provider credential is absent or inaccessible;
- the input media type is unsupported or unreadable;
- compatibility with the installed VoiceInk state cannot be established.

Runtime provider errors, authentication failures, rate limits, network
failures, cancellation, and timeouts must retain their distinct meaning in the
result. They must not be collapsed into an empty transcript.

An empty transcript is not success unless VoiceInk itself explicitly reports a
successful empty transcription for the same input and configuration.

Failure must not mutate the KnowledgeBase, input media, VoiceInk History,
VoiceInk Recordings, or VoiceInk configuration.

## Concurrency and lifecycle

The companion must behave correctly whether the VoiceInk UI is already running
or not. It must not require user interaction in either state.

Concurrent requests must not be confused or matched by recency alone. The
implementation may process them concurrently, serialize them, or reject an
additional request as busy, but each caller must receive an explicit result for
its own request.

Requests must support bounded completion. Cancellation and timeout must clean
up request-scoped resources and return a distinct non-success result.

The normal workflow does not require a permanent background watcher. Starting
or stopping any implementation component is the executor's choice as long as
invocation remains non-interactive and bounded.

## Non-goals

This work does not:

- automate general VoiceInk recording or dictation;
- replace VoiceInk's model, mode, provider, or credential settings;
- add an inbox watcher to VoiceInk;
- perform KnowledgeBase classification or synthesis;
- create or manage Apple Reminders;
- archive audio or transcripts;
- delete KnowledgeBase files;
- guarantee compatibility by silently preserving obsolete VoiceInk behavior;
- prescribe the implementation architecture.

## Acceptance criteria

The implementation is ready when all of the following are demonstrated:

1. A representative Russian M4A file is transcribed non-interactively through
   the enabled `Inbox` mode.
2. For the same input and configuration, the returned text matches the raw
   result of VoiceInk's **Transcribe Audio** flow after its deterministic
   non-AI cleanup.
3. Changing the `Inbox` mode's usable transcription model in VoiceInk changes
   the model used by the next request without companion reconfiguration.
4. Changing applicable language, prompt, formatting, vocabulary, or word
   replacements in VoiceInk is reflected in the next request.
5. Missing, duplicate, disabled, AI-enhanced, or otherwise invalid `Inbox`
   modes produce distinct configuration failures.
6. Missing models and missing or invalid credentials produce explicit failures
   without fallback.
7. A cloud-model request contacts only the provider configured by the `Inbox`
   mode.
8. The input file's checksum is unchanged after success, failure,
   cancellation, and timeout.
9. VoiceInk History and Recordings contain no new persistent artifact from the
   request.
10. VoiceInk settings are byte-for-byte or semantically unchanged, excluding
    unavoidable operating-system access timestamps.
11. No credential or unrelated VoiceInk data appears in output, logs,
    temporary files, or fixtures.
12. Requests work without user interaction both when VoiceInk is initially
    running and when it is initially closed.
13. Two overlapping requests are either associated with their correct results
    or one receives an explicit busy response; recency-based result guessing is
    not used.
14. An intentionally incompatible VoiceInk configuration or contract version
    is rejected before transcription with an actionable diagnostic.
15. Existing VoiceInk recording, file transcription, History, modes, updates,
    installation, signing, and launch behavior remain unchanged when the
    companion is not invoked.

Tests may use fakes for credentials, providers, and operating-system services.
At least one end-to-end test must use the installed VoiceInk configuration and
a non-sensitive audio fixture. Personal inbox audio and real credentials must
not be committed to the repository.
