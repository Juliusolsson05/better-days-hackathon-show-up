// Embeddings. Claude does not produce vectors -- Anthropic has no embeddings endpoint --
// so the vector half of the pipeline is Voyage and the reasoning half is Claude.
//
// voyage-4 gives 200M free tokens per account, which covers this entire project.

const KEY = Deno.env.get('VOYAGE_API_KEY')!;

/**
 * 256 dimensions, matching profile_vectors. voyage-4 embeddings are Matryoshka, so the
 * first 256 of the 2048 are a valid embedding on their own with negligible quality loss
 * at this scale -- and 256 keeps a million-row scan at 1GB instead of 4GB.
 *
 * THIS NUMBER IS BAKED INTO THE CLICKHOUSE SCHEMA. Changing it means reseeding.
 */
export const DIMS = 256;

/**
 * input_type is deliberately null. "query" and "document" are for asymmetric search --
 * a short question hunting through long documents. We compare people to people, which is
 * symmetric; mixing the two would quietly degrade every match with no error to show for it.
 */
export async function embed(texts: string[]): Promise<number[][]> {
  const res = await fetch('https://api.voyageai.com/v1/embeddings', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${KEY}` },
    body: JSON.stringify({
      input: texts,
      model: 'voyage-4',
      input_type: null,
      output_dimension: DIMS,
    }),
  });
  if (!res.ok) throw new Error(`voyage ${res.status}: ${await res.text()}`);
  const json = await res.json();
  return json.data.map((d: { embedding: number[] }) => d.embedding);
}

/**
 * Raw embeddings are anisotropic: every vector points into the same narrow cone, so any
 * two profiles score ~0.85 and the nearest-neighbour ranking collapses into noise.
 * Subtracting the population centroid restores the spread. Everything written to
 * profile_vectors goes through here first.
 */
export function center(v: number[], mean: number[]): number[] {
  return v.map((x, i) => x - mean[i]);
}

/**
 * The tags carry real signal and the passion field alone is one or two sentences -- too
 * short to embed cleanly on its own. Glue them together so the model has something to work with.
 */
export function profileText(p: { passion: string; tags: string[] }): string {
  return `Interests: ${p.tags.join(', ')}\n\nPassionate about: ${p.passion}`;
}
