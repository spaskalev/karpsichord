/*

This file is part of the karpsichord project
  at https://github.com/spaskalev/karpsichord

Copyright (C) 2022 Stanislav Paskalev <spaskalev@protonmail.com

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

*/

declare options "[midi:on]";
declare options "[nvoices:16]";

import("basics.lib");
import("filters.lib");
import("delays.lib");
import("maths.lib");
import("noises.lib");
import("envelopes.lib");
import("stdfaust.lib");
import("compressors.lib");
import("reverbs.lib");

// These UI elements are automatically set by Faust when using MIDI
midi_gate = button("gate");
midi_freq = hslider("freq",440,0,4096,1);
midi_gain = hslider("gain",0.5,0,1,0.01);

// The value of the current MIDI note, normalized to [0,1]
max_midi_freq = ba.midikey2hz(127);
min_midi_freq = ba.midikey2hz(0);
normalized_midi_freq = (midi_freq - min_midi_freq) / (max_midi_freq - min_midi_freq);

// Excitation noise source is white noise filtered by a two-element convolution filter
noise_source = hgroup("Noise compensation = noise * ((normalized midi frequency * m) + c)", noise : fir((.5, .5)) : * (attenuation)
with {
    attenuation = (normalized_midi_freq * m) + c;
    m = hslider("Multiplier", 1.25, -2, 2, 0.0001);
    c = hslider("Constant", 0.35, -2, 2, 0.0001);
});

noise_envelope(signal) = hgroup("Noise envelope/gain = (normalized midi frequency * m) + c", en.ar(attack, release, signal)
with {
    total_length = (normalized_midi_freq * m) + c;
    ratio = hslider("Attack/release ratio", 0.5, 0, 1, 0.1);
    m = hslider("Multiplier", -0.185, -1, 1, 0.0001);
    c = hslider("Constant", 0.045, -1, 1, 0.0001);
    attack = total_length * ratio;
    release = total_length * (1 - ratio);
});

// Generate excitation on trigger signal using a fire-and-forget envelope
initial_samples(signal) = (noise_source * noise_envelope(signal));

// A line equation that modifies the sample delay and therefore the notes' pitch
tuning_gradient = hgroup("Tuning gradient = (normalized midi frequency * m) + c", (m * normalized_midi_freq) + c
with {
    m = hslider("Multiplier",0.55,-2.0,2,0.01);
    c = hslider("Constant",-1.2,-5,5,0.1);
});

// The sample delay length. Based on the current sampling rate, note and compensation.
loop_delay = (ma.SR / midi_freq) + tuning_gradient;

// Sample delay via fifth-order Lagrange interpolation. Might be an overkill.
sample_delay(signal) = fdelay5(4096, loop_delay, signal);

// A stretched convolution filter that extends high notes' duration
string_filter(i) = hgroup("Stretch compensation = exp(normalized midi frequency)", (c*i) + (d * (i'))
with {
    d = S * 0.5;
    c = 1 - d;
    S = normalized_midi_freq
        : * (hslider("Input multiplier", 2.35, -10, 10, 0.01))
        : + (hslider("Input constant", -0.625, -10, 10, 0.01))
        : exp
        : * (hslider("Output multiplier", -0.1, -1, 1, 0.01))
        : + (hslider("Output constant", 0.35, -1, 1, 0.01));
});

// A log-based attenuation that shortens low notes' duration
string_decay(i) = hgroup("Decay compensation = min(0,999, 1 - log(normalized midi frequency))",(i*k)
with {
    k = min(0.999, 1 - ( normalized_midi_freq
                 : * (hslider("Input multiplier", 20, 0.01, 20, 0.01))
                 : + (hslider("Input constant", 0.05, -1, 1, 0.001))
                 : log
                 : * (hslider("Output multiplier", -0.005, -1, 1, 0.001))
                 : + (hslider("Output constant", 0, -1, 1, 0.001))));
});

// Pick position comb filter based on the loop delay for the current note.
pick_position(s) = select2(enabled, s, filter)
with {
    position = hslider("Pick position (relative) (set to zero to disable)", 0.15, 0, 0.5, 0.01);
    enabled = (position != 0);
    filter = delay(4096, position * loop_delay, s) : - (s);
};

process = midi_gate <: ((initial_samples : pick_position : (+ (_) : sample_delay  : string_filter : string_decay) ~ _)
          * (en.arfe(0.2, 0.4, 0))) : * (hslider("Voices attenuation", 0.4, 0, 1, 0.001)) <: _, _;

effect = hgroup("Effects: ", limiter_lad_N(2, .01, 1, .01, .1, 1) : dm.zita_rev_fdn(
    hslider("f1: crossover frequency (Hz) separating dc and midrange frequencies", 100, 1, 4000, 1),
    hslider("f2: frequency (Hz) above f1 where T60 = t60m/2 (see below)", 600, 1, 4000, 1),
    hslider("t60dc: desired decay time (t60) at frequency 0 (sec)", 0.1, 0, 10, 0.1),
    hslider("t60m: desired decay time (t60) at midrange frequencies (sec)", 3.5, 0, 10, 0.1),
    48000));
