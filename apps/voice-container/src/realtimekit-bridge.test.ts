import { describe, expect, it } from 'bun:test';
import { RealtimeKitBridge } from './realtimekit-bridge';

describe('RealtimeKitBridge HTML', () => {
  function html(): string {
    return new RealtimeKitBridge({
      botId: 'bot-1',
      meetingId: 'meeting-1',
      participantId: 'participant-1',
      authToken: 'token-1',
      roomToken: 'room-token',
      port: 1234,
      onInput: () => {},
      onQuietInput: () => {},
      onClosed: () => {},
    }).html();
  }

  it('listens to RealtimeKit map-level audioUpdate with the participant argument', () => {
    expect(html()).toContain(
      "meeting.participants.joined.on('audioUpdate', onParticipantAudioUpdate);",
    );
    expect(html()).toContain('function onParticipantAudioUpdate(participant, update)');
  });

  it('keeps remote human capture connected without echoing it through the browser output', () => {
    expect(html()).toContain('const silentSink = audioContext.createGain();');
    expect(html()).toContain('silentSink.gain.value = 0;');
    expect(html()).toContain('processor.connect(silentSink);');
  });

  it('falls back cleanly when a RealtimeKit room uses automatic audio subscription', () => {
    expect(html()).toContain('let manualSubscriptionUnavailable = false;');
    expect(html()).toContain("String(err).includes('ERR1206')");
    expect(html()).toContain('manual subscription unavailable; using auto audio');
  });

  it('filters bot/self audio and gates quiet room noise before OpenAI input', () => {
    expect(html()).toContain('const INPUT_RMS_GATE = 0.008;');
    expect(html()).toContain('function isSelfParticipant(participant)');
    expect(html()).toContain("v.startsWith('pendingbot:bot:')");
    expect(html()).toContain('function maybeSendInput(input)');
    expect(html()).toContain('suppressed quiet input frames');
    expect(html()).toContain('ignored local output audio track');
  });
});
