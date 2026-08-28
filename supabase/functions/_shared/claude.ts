// Claude does the reasoning half of the pipeline: turning free text into structured tags,
// picking a venue and activity for a group, and writing each person's question.
//
// Why both this and voyage.ts: the embedding finds the topic neighbourhood but cannot tell
// a stance from its opposite -- "I love hunting" and "I think hunting is barbaric" embed
// almost identically, because embeddings capture what you are talking about, not what you
// think about it. The tags extracted here are what stop the matcher from seating a vegan
// next to a hunter and calling it a great match. Embedding = recall, tags = precision.

import Anthropic from 'npm:@anthropic-ai/sdk@0.71.0';
import { z } from 'npm:zod@3.24.1';
// Structured output lives under `beta` in this SDK version: betaZodOutputFormat +
// client.beta.messages.parse + `output_format`. The non-beta client.messages.parse does not
// exist here and fails at RUNTIME with "not a function" -- nothing type-checks this repo,
// so it surfaces as a 500 from inside a sweep rather than at deploy.
import { betaZodOutputFormat } from 'npm:@anthropic-ai/sdk@0.71.0/helpers/beta/zod';

const client = new Anthropic({ apiKey: Deno.env.get('ANTHROPIC_API_KEY')! });

const ProfileTags = z.object({
  topics: z.array(z.string()).describe('3-6 normalised interest topics'),
  energy: z.enum(['calm', 'moderate', 'high']),
  indoor: z.boolean(),
  prefers_activity: z.boolean().describe('true = would rather do a thing, false = would rather talk'),
  alcohol_ok: z.boolean(),
  stance_flags: z.array(z.string()).describe(
    'Strongly held positions that would make a table hostile, e.g. "vegan", "hunting", "religious". Empty when none.',
  ),
});
export type ProfileTags = z.infer<typeof ProfileTags>;

/** Simple classification -- low effort is the right setting and keeps it fast. */
export async function extractTags(passion: string, tags: string[]): Promise<ProfileTags> {
  const res = await client.beta.messages.parse({
    model: 'claude-opus-5',
    max_tokens: 2000,
    output_format: betaZodOutputFormat(ProfileTags),
    messages: [{
      role: 'user',
      content: `Self-selected tags: ${tags.join(', ')}\n\nWhat they are passionate about:\n${passion}`,
    }],
    system:
      'Extract structured matching attributes from a group-matching profile. stance_flags is ' +
      'the important field: record positions strong enough that pairing this person with ' +
      'someone holding the opposite view would ruin the evening.',
  });
  if (!res.parsed_output) throw new Error('tag extraction returned no parsed output');
  return res.parsed_output;
}

const GroupPlan = z.object({
  venue: z.object({
    name: z.string(),
    address: z.string(),
    why: z.string().describe('One line the group will actually read'),
  }),
  activity: z.string(),
  questions: z.array(z.object({
    user_id: z.string(),
    pair_with: z.string(),
    question: z.string().describe('Asks THIS person about THEIR pair\'s passion, by name'),
  })),
});
export type GroupPlan = z.infer<typeof GroupPlan>;

/**
 * One call per formed group. Adaptive thinking because pairing six people and writing a
 * question tied to each pair's actual passion is the part worth thinking about.
 */
export async function planGroup(
  members: { user_id: string; display_name: string; passion: string; tags: string[] }[],
  city: string,
): Promise<GroupPlan> {
  const res = await client.beta.messages.parse({
    model: 'claude-opus-5',
    max_tokens: 16000,
    // Thinking tokens count against max_tokens, and a structured object truncated mid-write
    // surfaces as a null parsed_output rather than an error -- hence the explicit budget well
    // under max_tokens, leaving room for the object itself. ('adaptive' is not a valid type
    // in this SDK version; only 'enabled' and 'disabled'.)
    thinking: { type: 'enabled', budget_tokens: 6000 },
    output_format: betaZodOutputFormat(GroupPlan),
    messages: [{
      role: 'user',
      content: `City: ${city}\n\n${members.map((m) =>
        `- ${m.user_id} (${m.display_name}) | ${m.tags.join(', ')} | ${m.passion}`).join('\n')}`,
    }],
    system:
      'Plan one evening for these six people who have never met. Pick a real venue in the ' +
      'named city and an activity that suits the group. Then pair everyone up (each person ' +
      'appears exactly once as user_id) and write each person a question about their ' +
      "pair's passion, using the pair's first name. The question should be answerable at " +
      'length by someone who cares about it, and should not be answerable yes or no.',
  });
  if (!res.parsed_output) throw new Error('group planning returned no parsed output');
  return res.parsed_output;
}
