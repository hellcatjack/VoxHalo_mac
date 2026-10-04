import pytest

from voxbridge.tts.jobs import (
    RevisionStableTTSBuffer,
    TTSJobNotFound,
    TTSJobRegistry,
    TTSQueueFull,
)


class FakeClock:
    def __init__(self, value: float) -> None:
        self.value = value

    def __call__(self) -> float:
        return self.value

    def advance(self, seconds: float) -> None:
        self.value += seconds


def test_diagnostics_do_not_change_release_or_source_clock():
    clock = FakeClock(0)
    buffer = RevisionStableTTSBuffer(stable_sec=3, require_confirmation=True, clock=clock)
    buffer.register('s', 1, 0)
    clock.advance(1)
    buffer.mark_ready('s', 1, '译文。', 'Chinese')
    clock.advance(2)
    for _ in range(5):
        row = buffer.diagnostics()[0]
        assert row['release_policy'] == 'revision_confirmation'
        assert row['source_quiet_age_ms'] == 3000
        assert row['translation_ready_age_ms'] == 2000
        assert row['remaining_ms'] is None
        assert not row['offered']
    assert buffer.drain() == []
    buffer.confirm_revision('s', 1)
    assert buffer.drain()[0].sentence_id == 's'


@pytest.mark.parametrize('seal', [False, True])
def test_new_revision_cannot_inherit_confirmation_or_final_seal(seal):
    clock = FakeClock(0)
    buffer = RevisionStableTTSBuffer(stable_sec=3, hold_latest_until_sealed=True,
                                    confirmed_urgent_stable_sec=1, clock=clock)
    buffer.register('s', 1, 0)
    (buffer.seal_through if seal else buffer.confirm_through)(0)
    buffer.register('s', 2, 0)
    buffer.mark_ready('s', 2, '修订后的完整句子。', 'Chinese')
    buffer.set_playback_pressure(urgent=True)
    clock.advance(10)
    assert buffer.drain() == []
    buffer.seal_through(0)
    assert [x.revision for x in buffer.drain()] == [2]


def test_prepared_release_remains_replaceable_until_shared_commit():
    buffer = RevisionStableTTSBuffer(stable_sec=0, defer_commit=True)
    for sid, order in [('first', 0), ('second', 1)]:
        buffer.register(sid, 1, order)
        buffer.mark_ready(sid, 1, sid, 'Chinese')
    assert [x.text for x in buffer.drain()] == ['first']
    assert buffer.drain() == []
    assert buffer.next_deadline() is None
    assert buffer.register('first', 2, 0).accepted
    buffer.mark_ready('first', 2, 'corrected', 'Chinese')
    assert not buffer.commit('first', 1)
    assert [x.text for x in buffer.drain()] == ['corrected']
    assert buffer.commit('first', 2)
    assert buffer.register('first', 3, 0).late_after_release
    assert [x.text for x in buffer.drain()] == ['second']


def test_final_drain_flushes_pending_sentences_without_repeating_offered_head():
    buffer = RevisionStableTTSBuffer(stable_sec=0, defer_commit=True)
    for i in range(3):
        buffer.register(str(i), 1, i)
        buffer.mark_ready(str(i), 1, str(i), 'Chinese')
    assert [x.text for x in buffer.drain()] == ['0']
    assert [x.text for x in buffer.drain(force=True)] == ['1', '2']
    assert buffer.pending_count == 0


def test_failed_unpublished_head_does_not_block_next_sentence():
    buffer = RevisionStableTTSBuffer(stable_sec=0, defer_commit=True)
    for i in range(2):
        buffer.register(str(i), 1, i)
        buffer.mark_ready(str(i), 1, str(i), 'Chinese')
    buffer.drain()
    buffer.mark_failed('0', 1)
    assert [x.text for x in buffer.drain()] == ['1']


def test_withdrawn_hypothesis_revokes_a_ready_but_unpublished_sentence():
    buffer = RevisionStableTTSBuffer(stable_sec=0, defer_commit=True, require_confirmation=True)
    buffer.register('s', 1, 0)
    buffer.mark_ready('s', 1, '原句。', 'Chinese')
    buffer.confirm_revision('s', 1)
    assert len(buffer.drain()) == 1 and buffer.can_commit('s', 1)
    assert buffer.revoke_confirmation('s', 1)
    assert not buffer.can_commit('s', 1)
    assert buffer.retry_pending('s', 1)
    assert buffer.drain() == []
    buffer.confirm_revision('s', 1)
    assert len(buffer.drain()) == 1
    assert buffer.commit('s', 1)
    assert not buffer.revoke_confirmation('s', 1)
    assert buffer.can_commit('s', 1)


def test_reconfirmation_cannot_reuse_an_old_offers_quiet_window():
    clock = FakeClock(0)
    buffer = RevisionStableTTSBuffer(stable_sec=3, defer_commit=True, require_confirmation=True, clock=clock)
    buffer.register('s', 1, 0)
    buffer.mark_ready('s', 1, '完整句子。', 'Chinese')
    buffer.confirm_revision('s', 1)
    clock.advance(3)
    buffer.drain()
    clock.advance(.1)
    buffer.revoke_confirmation('s', 1)
    clock.advance(.1)
    buffer.confirm_revision('s', 1, allow_urgent=False)
    assert not buffer.can_commit('s', 1)
    clock.advance(2.9)
    assert buffer.can_commit('s', 1)


def test_urgent_playback_shortens_only_confirmed_source_and_reuses_source_clock():
    clock = FakeClock(100)
    buffer = RevisionStableTTSBuffer(stable_sec=3, hold_latest_until_sealed=True,
                                    confirmed_urgent_stable_sec=1, clock=clock)
    buffer.register("s", 1, 0)
    clock.advance(1.2)
    buffer.mark_ready("s", 1, "Ready.", "English")
    buffer.set_playback_pressure(urgent=True)
    assert buffer.drain() == []  # Latest source still lacks confirmation.
    buffer.confirm_through(0)
    released = buffer.drain()
    assert [(x.text, x.release_reason, x.source_quiet_age_ms) for x in released] == [
        ("Ready.", "rollback_safe_urgent", 1200)]


def test_playback_pressure_fallback_restores_normal_window_and_revision_clock():
    clock = FakeClock(100)
    buffer = RevisionStableTTSBuffer(stable_sec=3, confirmed_urgent_stable_sec=1, clock=clock)
    buffer.register("s", 1, 0)
    buffer.confirm_through(0)
    buffer.mark_ready("s", 1, "Before.", "English")
    buffer.set_playback_pressure(urgent=True)
    clock.advance(0.9)
    buffer.register("s", 2, 0)
    buffer.mark_ready("s", 2, "After.", "English")
    clock.advance(0.9)
    assert buffer.drain() == []
    buffer.set_playback_pressure(urgent=False)
    clock.advance(0.2)
    assert buffer.drain() == []
    clock.advance(1.9)
    assert [x.text for x in buffer.drain()] == ["After."]


def create_job(registry: TTSJobRegistry, **overrides):
    values = {
        "owner_key": "owner-a",
        "client_id": "client-a-12345678",
        "sentence_id": "s1",
        "revision": 1,
        "source_order": 0,
        "target_language": "English",
        "text": "Stable translation.",
    }
    values.update(overrides)
    return registry.create(**values)


def test_registry_enforces_owner_and_acknowledgement():
    clock = FakeClock(100.0)
    registry = TTSJobRegistry(ttl_sec=30, max_client_jobs=4, clock=clock)
    job = create_job(registry)

    assert registry.get(job.job_id, "owner-a").text == "Stable translation."
    with pytest.raises(TTSJobNotFound):
        registry.get(job.job_id, "owner-b")

    assert registry.acknowledge(job.job_id, "owner-a") is True
    with pytest.raises(TTSJobNotFound):
        registry.get(job.job_id, "owner-a")


def test_registry_never_evicts_unread_job_when_full():
    registry = TTSJobRegistry(ttl_sec=30, max_client_jobs=1)
    first = create_job(registry)

    with pytest.raises(TTSQueueFull):
        create_job(registry, sentence_id="s2", source_order=1)

    assert registry.get(first.job_id, "owner-a").job_id == first.job_id


def test_registry_expires_jobs_without_exposing_them():
    clock = FakeClock(100.0)
    registry = TTSJobRegistry(ttl_sec=30, max_client_jobs=4, clock=clock)
    job = create_job(registry)

    clock.value = 130.01

    with pytest.raises(TTSJobNotFound):
        registry.get(job.job_id, "owner-a")
    assert registry.prune() == 0


def test_registry_cancels_only_matching_owner_and_client():
    registry = TTSJobRegistry(ttl_sec=30, max_client_jobs=4)
    first = create_job(registry, sentence_id="s1")
    second = create_job(registry, sentence_id="s2", client_id="client-b-12345678")
    third = create_job(
        registry,
        owner_key="owner-b",
        client_id="client-a-12345678",
        sentence_id="s3",
    )

    assert registry.cancel_client("owner-a", "client-a-12345678") == 1
    with pytest.raises(TTSJobNotFound):
        registry.get(first.job_id, "owner-a")
    assert registry.get(second.job_id, "owner-a").job_id == second.job_id
    assert registry.get(third.job_id, "owner-b").job_id == third.job_id


def test_registry_caches_audio_without_mutating_text_snapshot():
    registry = TTSJobRegistry(ttl_sec=30, max_client_jobs=4)
    job = create_job(registry)

    cached = registry.cache_audio(job.job_id, "owner-a", b"RIFF-audio")

    assert cached.audio_bytes == b"RIFF-audio"
    assert cached.text == "Stable translation."
    assert job.audio_bytes is None


def test_stability_buffer_withholds_ready_revision_until_quiet_window():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(stable_sec=3.0, clock=clock)

    result = buffer.register("s1", revision=1, source_order=0)
    assert result.accepted is True
    assert buffer.mark_ready("s1", 1, "first", "English") is True
    assert buffer.drain() == []
    assert buffer.next_deadline() == pytest.approx(103.0)

    clock.advance(2.999)
    assert buffer.drain() == []
    clock.advance(0.001)
    ready = buffer.drain()

    assert [(item.sentence_id, item.revision, item.text) for item in ready] == [
        ("s1", 1, "first")
    ]
    assert ready[0].release_reason == "quiet_window"
    assert ready[0].source_quiet_age_ms == 3000
    assert ready[0].translation_ready_age_ms == 3000


def test_revision_update_discards_old_translation_and_restarts_window():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(stable_sec=3.0, clock=clock)
    buffer.register("s1", 1, 0)
    assert buffer.mark_ready("s1", 1, "old", "English") is True

    clock.advance(2.9)
    update = buffer.register("s1", 2, 0)

    assert update.reset is True
    assert update.previous_revision == 1
    assert update.previous_ready is True
    assert update.previous_quiet_age_ms == 2900
    assert buffer.mark_ready("s1", 1, "stale", "English") is False
    assert buffer.mark_ready("s1", 2, "new", "English") is True
    clock.advance(2.9)
    assert buffer.drain() == []
    clock.advance(0.1)
    assert [item.text for item in buffer.drain()] == ["new"]


def test_newest_source_uses_additional_revision_grace():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(
        stable_sec=3.0,
        latest_revision_grace_sec=4.0,
        clock=clock,
    )
    buffer.register("s1", 1, 0)
    buffer.mark_ready("s1", 1, "first", "English")

    clock.advance(3.0)
    assert buffer.drain() == []
    assert buffer.next_deadline() == pytest.approx(107.0)
    wait = buffer.wait_state("s1")
    assert wait is not None
    assert wait.required_quiet_ms == 7000
    assert wait.remaining_ms == 4000
    assert wait.waiting_for_latest_grace is True

    clock.advance(4.0)
    ready = buffer.drain()

    assert [item.text for item in ready] == ["first"]
    assert ready[0].release_reason == "latest_revision_grace"


def test_newest_source_can_require_segment_seal_before_release():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(
        stable_sec=3.0,
        latest_revision_grace_sec=4.0,
        hold_latest_until_sealed=True,
        clock=clock,
    )
    buffer.register("s1", 1, 0)
    buffer.mark_ready("s1", 1, "first", "English")

    clock.advance(60.0)
    assert buffer.drain() == []
    assert buffer.next_deadline() is None
    wait = buffer.wait_state("s1")
    assert wait is not None
    assert wait.required_quiet_ms == -1
    assert wait.remaining_ms == -1
    assert wait.waiting_for_latest_grace is False
    assert wait.waiting_for_segment_seal is True

    buffer.register("s2", 1, 1)
    assert [item.text for item in buffer.drain()] == ["first"]
    buffer.mark_ready("s2", 1, "second", "English")
    clock.advance(60.0)
    assert buffer.drain() == []

    assert buffer.seal_through(1) is True
    ready = buffer.drain()
    assert [item.text for item in ready] == ["second"]
    assert ready[0].release_reason == "source_sealed"


def test_successor_removes_latest_grace_from_preceding_source():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(
        stable_sec=3.0,
        latest_revision_grace_sec=4.0,
        clock=clock,
    )
    buffer.register("s1", 1, 0)
    buffer.mark_ready("s1", 1, "first", "English")

    clock.advance(3.0)
    buffer.register("s2", 1, 1)
    ready = buffer.drain()

    assert [item.text for item in ready] == ["first"]
    assert ready[0].release_reason == "quiet_window"


def test_rollback_confirmed_newest_source_uses_base_quiet_window():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(
        stable_sec=3.0,
        latest_revision_grace_sec=4.0,
        clock=clock,
    )
    buffer.register("s1", 1, 0)
    buffer.mark_ready("s1", 1, "first", "English")

    assert buffer.confirm_through(0) is True
    assert buffer.next_deadline() == pytest.approx(103.0)
    wait = buffer.wait_state("s1")
    assert wait is not None
    assert wait.required_quiet_ms == 3000
    assert wait.waiting_for_latest_grace is False

    clock.advance(3.0)
    ready = buffer.drain()

    assert [item.text for item in ready] == ["first"]
    assert ready[0].release_reason == "rollback_safe"


def test_sealed_newest_source_releases_without_arbitrary_timer():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(
        stable_sec=3.0,
        latest_revision_grace_sec=4.0,
        clock=clock,
    )
    buffer.register("s1", 1, 0)
    buffer.mark_ready("s1", 1, "final", "English")

    assert buffer.seal_through(0) is True
    ready = buffer.drain()

    assert [item.text for item in ready] == ["final"]
    assert ready[0].release_reason == "source_sealed"


def test_translation_ready_after_seal_releases_current_revision():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(
        stable_sec=3.0,
        latest_revision_grace_sec=4.0,
        clock=clock,
    )
    buffer.register("s1", 1, 0)

    buffer.seal_through(0)
    assert buffer.drain() == []
    buffer.mark_ready("s1", 1, "final", "English")

    assert [item.release_reason for item in buffer.drain()] == ["source_sealed"]


def test_latest_source_revision_restarts_full_grace_window():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(
        stable_sec=3.0,
        latest_revision_grace_sec=4.0,
        clock=clock,
    )
    buffer.register("s1", 1, 0)
    buffer.mark_ready("s1", 1, "old", "English")
    clock.advance(6.5)

    update = buffer.register("s1", 2, 0)
    buffer.mark_ready("s1", 2, "new", "English")
    clock.advance(6.5)

    assert update.reset is True
    assert buffer.drain() == []
    clock.advance(0.5)
    assert [item.text for item in buffer.drain()] == ["new"]


def test_stability_buffer_validates_grace_and_seals_monotonically():
    with pytest.raises(ValueError, match="latest_revision_grace_sec"):
        RevisionStableTTSBuffer(stable_sec=3.0, latest_revision_grace_sec=-0.1)

    buffer = RevisionStableTTSBuffer(stable_sec=3.0, latest_revision_grace_sec=4.0)
    with pytest.raises(ValueError, match="source_order"):
        buffer.seal_through(-1)
    assert buffer.seal_through(2) is True
    assert buffer.seal_through(1) is False
    assert buffer.seal_through(2) is False
    assert buffer.seal_through(3) is True


def test_translation_finishing_after_source_deadline_releases_immediately():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(stable_sec=3.0, clock=clock)
    buffer.register("s1", 1, 0)

    clock.advance(4.0)
    assert buffer.mark_ready("s1", 1, "late translation", "English") is True

    ready = buffer.drain()
    assert [item.text for item in ready] == ["late translation"]
    assert ready[0].source_quiet_age_ms == 4000
    assert ready[0].translation_ready_age_ms == 0


def test_release_age_preserves_zero_monotonic_timestamp():
    clock = FakeClock(0.0)
    buffer = RevisionStableTTSBuffer(stable_sec=3.0, clock=clock)
    buffer.register("s1", 1, 0)
    buffer.mark_ready("s1", 1, "translated", "English")

    clock.advance(3.0)
    ready = buffer.drain()

    assert ready[0].translation_ready_age_ms == 3000


def test_stability_buffer_preserves_order_and_skips_failed_head():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(stable_sec=3.0, clock=clock)
    buffer.register("s1", 1, 0)
    buffer.register("s2", 1, 1)
    assert buffer.mark_ready("s2", 1, "second", "English") is True

    clock.advance(3.0)
    assert buffer.drain() == []
    assert buffer.mark_failed("s1", 1) is True

    ready = buffer.drain()
    assert [item.sentence_id for item in ready] == ["s2"]


def test_wait_state_reports_quiet_time_and_order_blocking():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(stable_sec=3.0, clock=clock)
    buffer.register("s1", 1, 0)
    buffer.register("s2", 1, 1)
    buffer.mark_ready("s2", 1, "second", "English")

    clock.advance(1.25)
    wait = buffer.wait_state("s2")

    assert wait is not None
    assert wait.quiet_age_ms == 1250
    assert wait.required_quiet_ms == 3000
    assert wait.remaining_ms == 1750
    assert wait.blocked_by_earlier is True


def test_force_drain_releases_only_current_ready_revisions():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(stable_sec=60.0, clock=clock)
    buffer.register("s1", 1, 0)
    buffer.register("s2", 1, 1)
    buffer.register("s2", 2, 1)
    assert buffer.mark_ready("s1", 1, "first", "English") is True
    assert buffer.mark_ready("s2", 1, "stale", "English") is False
    assert buffer.mark_ready("s2", 2, "second", "English") is True

    ready = buffer.drain(force=True)

    assert [(item.revision, item.text) for item in ready] == [(1, "first"), (2, "second")]
    assert {item.release_reason for item in ready} == {"final_force"}


def test_revision_after_release_is_reported_and_never_emitted_twice():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(stable_sec=0.0, clock=clock)
    buffer.register("s1", 1, 0)
    buffer.mark_ready("s1", 1, "spoken", "English")
    assert len(buffer.drain()) == 1

    clock.advance(1.25)
    late = buffer.register("s1", 2, 0)

    assert late.accepted is False
    assert late.late_after_release is True
    assert late.released_revision == 1
    assert late.elapsed_since_release_ms == 1250
    assert buffer.mark_ready("s1", 2, "changed", "English") is False
    assert buffer.drain() == []


def test_stability_buffer_rejects_identity_changes():
    buffer = RevisionStableTTSBuffer(stable_sec=3.0)
    buffer.register("s1", 1, 0)

    with pytest.raises(ValueError, match="cannot change source_order"):
        buffer.register("s1", 2, 1)
    with pytest.raises(ValueError, match="already registered"):
        buffer.register("s2", 1, 0)


def test_stability_buffer_reset_discards_all_session_state():
    clock = FakeClock(100.0)
    buffer = RevisionStableTTSBuffer(stable_sec=3.0, clock=clock)
    buffer.register("s1", 1, 0)
    buffer.mark_ready("s1", 1, "old", "English")

    buffer.reset()
    buffer.register("s2", 1, 0)
    buffer.mark_ready("s2", 1, "new", "English")
    clock.advance(3.0)

    assert [item.sentence_id for item in buffer.drain()] == ["s2"]


def test_confirmed_word_and_boundary_history_is_reused_before_translation_registration():
    clock = FakeClock(10)
    buffer = RevisionStableTTSBuffer(stable_sec=3, require_confirmation=True,
                                    defer_commit=True, clock=clock)
    buffer.register('s', 1, 0)
    buffer.mark_ready('s', 1, '完整译文。', 'Chinese')
    buffer.confirm_revision('s', 1, evidence_age_sec=2.5)
    assert buffer.next_deadline() == pytest.approx(10.5)
    assert not buffer.drain()
    clock.advance(.5)
    assert [x.sentence_id for x in buffer.drain()] == ['s']
    assert buffer.can_commit('s', 1)
    assert buffer.commit('s', 1)


def test_revised_or_withdrawn_source_never_inherits_old_history():
    clock = FakeClock(10)
    buffer = RevisionStableTTSBuffer(stable_sec=3, require_confirmation=True,
                                    defer_commit=True, clock=clock)
    buffer.register('s', 1, 0)
    buffer.mark_ready('s', 1, '旧译文。', 'Chinese')
    buffer.confirm_revision('s', 1, evidence_age_sec=8)
    assert buffer.drain()
    buffer.revoke_confirmation('s', 1)
    assert not buffer.can_commit('s', 1)
    buffer.retry_pending('s', 1)
    buffer.confirm_revision('s', 1, evidence_age_sec=0)
    assert not buffer.drain()
    buffer.register('s', 2, 0)
    buffer.mark_ready('s', 2, '新译文，保留所有尾部。', 'Chinese')
    clock.advance(10)
    assert not buffer.drain()
    assert not buffer.confirm_revision('s', 1, evidence_age_sec=20)
    assert not buffer.drain()
    buffer.confirm_revision('s', 2, evidence_age_sec=0)
    assert [x.revision for x in buffer.drain()] == [2]


@pytest.mark.parametrize('age', [-1, float('inf'), float('nan')])
def test_invalid_confirmation_history_is_rejected(age):
    buffer = RevisionStableTTSBuffer(stable_sec=3)
    with pytest.raises(ValueError):
        buffer.confirm_revision('s', 1, evidence_age_sec=age)


@pytest.mark.parametrize('child_state', ['waiting', 'ready', 'offered'])
def test_superseded_occurrence_is_terminal_for_late_translation_and_source_events(child_state):
    clock = FakeClock(0)
    buffer = RevisionStableTTSBuffer(
        stable_sec=3, defer_commit=True, require_confirmation=True, clock=clock,
    )
    buffer.register('owner', 1, 0)
    buffer.register('absorbed', 1, 1)
    if child_state != 'waiting':
        buffer.mark_ready('absorbed', 1, '重复的旧译文。', 'Chinese')
    if child_state == 'offered':
        # An unpublished preparation may already have been offered by the
        # surrounding scheduler. Supersession must revoke this flag as well.
        buffer._entries[1].offered = True

    assert buffer.register('owner', 2, 0).accepted
    assert buffer.supersede('absorbed', 1, replacement_sentence_id='owner', replacement_revision=2)
    replacement = buffer.supersession('absorbed')
    assert replacement is not None
    assert (replacement.sentence_id, replacement.revision, replacement.source_order) == ('absorbed', 1, 1)
    assert (replacement.replacement_sentence_id, replacement.replacement_revision,
            replacement.replacement_source_order) == ('owner', 2, 0)
    assert buffer.is_superseded('absorbed')
    assert not buffer.is_committed('absorbed')
    assert buffer.pending_count == 1
    row = next(item for item in buffer.diagnostics() if item['sentence_id'] == 'absorbed')
    assert row['status'] == 'superseded'
    assert row['release_policy'] == 'source_superseded'
    assert row['replacement_sentence_id'] == 'owner'
    assert row['replacement_revision'] == 2
    assert not row['offered']

    for revision in (0, 1, 2, 50):
        registration = buffer.register('absorbed', revision, 1)
        assert not registration.accepted and registration.superseded
        assert registration.replacement_sentence_id == 'owner'
        assert registration.replacement_revision == 2
        assert not buffer.mark_ready('absorbed', revision, '迟到译文。', 'Chinese')
        assert not buffer.mark_failed('absorbed', revision)
        assert not buffer.confirm_revision('absorbed', revision, evidence_age_sec=100)
        assert not buffer.revoke_confirmation('absorbed', revision)
        assert not buffer.retry_pending('absorbed', revision)
        assert not buffer.can_commit('absorbed', revision)
        assert not buffer.commit('absorbed', revision)
    # A late callback with a stale order is terminal too, not a service error.
    assert buffer.register('absorbed', 2, 99).superseded

    buffer.mark_ready('owner', 2, '合并后保留了完整内容。', 'Chinese')
    clock.advance(100)
    assert buffer.drain() == []  # Supersession does not weaken confirmation.
    buffer.confirm_through(1)
    buffer.seal_through(1)
    assert [(item.sentence_id, item.revision) for item in buffer.drain(force=True)] == [('owner', 2)]
    assert buffer.pending_count == 0
    assert buffer.is_committed('owner')
    assert buffer.is_superseded('absorbed')
    assert not buffer.can_commit('absorbed', 1)
    assert not buffer.mark_ready('absorbed', 1, '不能恢复。', 'Chinese')
    assert buffer.drain(force=True) == []


def test_supersession_preflight_checks_old_owner_revision_without_mutating_it():
    buffer = RevisionStableTTSBuffer(stable_sec=0, defer_commit=True)
    buffer.register('owner', 4, 0)
    buffer.register('first-child', 1, 1)
    buffer.register('second-child', 3, 2)
    children = [('first-child', 1), ('second-child', 3)]
    assert buffer.can_supersede_many('owner', 5, children, expected_owner_revision=4)
    assert not buffer.can_supersede_many('owner', 5, children)
    assert not buffer.can_supersede_many('owner', 5, children, expected_owner_revision=3)
    assert not buffer.can_supersede_many('owner', 3, children, expected_owner_revision=4)
    assert not buffer.is_superseded('first-child')
    assert buffer.pending_count == 3

    assert buffer.register('owner', 5, 0).accepted
    assert buffer.can_supersede_many('owner', 5, children)
    assert buffer.supersede_many('owner', 5, children)
    assert buffer.pending_count == 1
    buffer.mark_ready('owner', 5, '完整合并译文。', 'Chinese')
    assert [item.sentence_id for item in buffer.drain()] == ['owner']
    assert buffer.commit('owner', 5)
    # Cursor advances across retired slots without an extra callback or drain.
    buffer.register('next', 1, 3)
    buffer.mark_ready('next', 1, '下一句。', 'Chinese')
    assert not buffer.wait_state('next').blocked_by_earlier
    assert buffer.next_deadline() is not None
    assert [item.sentence_id for item in buffer.drain()] == ['next']


@pytest.mark.parametrize('children', [
    [('first-child', 1), ('missing', 1)],
    [('first-child', 1), ('second-child', 2)],
    [('first-child', 1), ('first-child', 1)],
    [('first-child', 1), ('owner', 1)],
    [],
])
def test_supersession_invalid_group_cannot_partially_retire_children(children):
    buffer = RevisionStableTTSBuffer(stable_sec=0, defer_commit=True)
    for sid, order in [('owner', 0), ('first-child', 1), ('second-child', 2)]:
        buffer.register(sid, 1, order)
        buffer.mark_ready(sid, 1, sid, 'English')
    before = buffer.diagnostics()
    assert not buffer.can_supersede_many('owner', 1, children)
    assert not buffer.supersede_many('owner', 1, children)
    assert buffer.pending_count == 3
    assert not buffer.is_superseded('first-child')
    assert not buffer.is_superseded('second-child')
    assert [(row['sentence_id'], row['status']) for row in buffer.diagnostics()] == [
        (row['sentence_id'], row['status']) for row in before
    ]
    assert [item.sentence_id for item in buffer.drain(force=True)] == ['owner', 'first-child', 'second-child']


def test_committed_source_or_committed_owner_can_never_be_superseded():
    buffer = RevisionStableTTSBuffer(stable_sec=0, defer_commit=True)
    for sid, order in [('owner', 0), ('child', 1), ('later', 2)]:
        buffer.register(sid, 1, order)
        buffer.mark_ready(sid, 1, sid, 'English')
    buffer.drain()
    assert buffer.commit('owner', 1)
    assert buffer.is_committed('owner')
    assert not buffer.supersede_many('owner', 1, [('child', 1)])
    buffer.drain()
    assert buffer.commit('child', 1)
    assert buffer.is_committed('child')
    assert not buffer.supersede('child', 1, replacement_sentence_id='later', replacement_revision=1)
    assert not buffer.is_superseded('child')
    assert buffer.can_commit('child', 1)
    assert buffer.register('child', 2, 1).late_after_release
    assert [item.sentence_id for item in buffer.drain()] == ['later']


def test_supersession_does_not_dedupe_an_independent_repeated_sentence():
    buffer = RevisionStableTTSBuffer(stable_sec=0, defer_commit=True)
    for sid, order in [('owner', 0), ('absorbed', 1), ('independent-repeat', 2)]:
        buffer.register(sid, 1, order)
    buffer.register('owner', 2, 0)
    buffer.mark_ready('owner', 2, '我们必须谨慎，我们必须谨慎。', 'Chinese')
    buffer.mark_ready('absorbed', 1, '我们必须谨慎。', 'Chinese')
    buffer.mark_ready('independent-repeat', 1, '我们必须谨慎。', 'Chinese')
    assert buffer.supersede_many('owner', 2, [('absorbed', 1)])
    assert [(item.sentence_id, item.text) for item in buffer.drain(force=True)] == [
        ('owner', '我们必须谨慎，我们必须谨慎。'),
        ('independent-repeat', '我们必须谨慎。'),
    ]


@pytest.mark.parametrize('hold_latest', [False, True])
def test_absorbed_successor_cannot_remove_owners_latest_source_hold_or_grace(hold_latest):
    clock = FakeClock(0)
    buffer = RevisionStableTTSBuffer(
        stable_sec=3, latest_revision_grace_sec=4,
        hold_latest_until_sealed=hold_latest, defer_commit=True, clock=clock,
    )
    buffer.register('owner', 1, 0)
    buffer.register('absorbed-tail', 1, 1)
    buffer.register('owner', 2, 0)
    assert buffer.supersede_many('owner', 2, [('absorbed-tail', 1)])
    buffer.mark_ready('owner', 2, '整个最新源句。', 'Chinese')
    clock.advance(3)
    assert buffer.drain() == []
    state = buffer.wait_state('owner')
    assert state is not None
    assert state.waiting_for_segment_seal == hold_latest
    assert state.waiting_for_latest_grace != hold_latest
    clock.advance(4)
    if hold_latest:
        assert buffer.drain() == []
        buffer.seal_through(1)
    assert [item.sentence_id for item in buffer.drain()] == ['owner']


def test_superseded_owner_and_children_reset_only_at_new_session():
    buffer = RevisionStableTTSBuffer(stable_sec=0, defer_commit=True)
    buffer.register('owner', 1, 0)
    buffer.register('child', 1, 1)
    assert buffer.supersede_many('owner', 1, [('child', 1)])
    buffer.mark_ready('owner', 1, '完整译文。', 'Chinese')
    buffer.drain(force=True)
    buffer.reset()
    assert not buffer.is_committed('owner')
    assert not buffer.is_superseded('child')
    assert buffer.supersession('child') is None
    assert buffer.register('child', 1, 0).accepted
    buffer.mark_ready('child', 1, '新会话。', 'Chinese')
    assert [item.sentence_id for item in buffer.drain(force=True)] == ['child']
