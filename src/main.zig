pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Initialize tokenizer with default pattern
    var tokenizer: lib.Tokenizer = try .init(allocator);
    // Simple input text
    const input =
        \\Conceive the joy of a lover of nature who, leaving the art galleries,
        \\wanders out among the trees and wild flowers and birds that the
        \\pictures of the galleries have sentimentalised. It is some such joy
        \\that the man who truly loves the noblest in letters feels when tasting
        \\for the first time the simple delights of Russian literature. French
        \\and English and German authors, too, occasionally, offer works of
        \\lofty, simple naturalness; but the very keynote to the whole of
        \\Russian literature is simplicity, naturalness, veraciousness.
        \\
        \\Another essentially Russian trait is the quite unaffected conception
        \\that the lowly are on a plane of equality with the so-called upper
        \\classes. When the Englishman Dickens wrote with his profound pity and
        \\understanding of the poor, there was yet a bit; of remoteness,
        \\perhaps, even, a bit of caricature, in his treatment of them. He
        \\showed their sufferings to the rest of the world with a "Behold how
        \\the other half lives!" The Russian writes of the poor, as it were,
        \\from within, as one of them, with no eye to theatrical effect upon the
        \\well-to-do. There is no insistence upon peculiar virtues or vices. The
        \\poor are portrayed just as they are, as human beings like the rest of
        \\us. A democratic spirit is reflected, breathing a broad humanity, a
        \\true universality, an unstudied generosity that proceed not from the
        \\intellectual conviction that to understand all is to forgive all, but
        \\from an instinctive feeling that no man has the right to set himself
        \\up as a judge over another, that one can only observe and record.
        \\
        \\In 1834 two short stories appeared, _The Queen of Spades_, by Pushkin,
        \\and _The Cloak_, by Gogol. The first was a finishing-off of the old,
        \\outgoing style of romanticism, the other was the beginning of the new,
        \\the characteristically Russian style. We read Pushkin's _Queen of
        \\Spades_, the first story in the volume, and the likelihood is we shall
        \\enjoy it greatly. "But why is it Russian?" we ask. The answer is, "It
        \\is not Russian." It might have been printed in an American magazine
        \\over the name of John Brown. But, now, take the very next story in the
        \\volume, _The Cloak_. "Ah," you exclaim, "a genuine Russian story,
        \\Surely. You cannot palm it off on me over the name of Jones or Smith."
        \\Why? Because _The Cloak_ for the first time strikes that truly Russian
        \\note of deep sympathy with the disinherited. It is not yet wholly free
        \\from artificiality, and so is not yet typical of the purely realistic
        \\fiction that reached its perfected development in Turgenev and
        \\Tolstoy.
        \\
        \\Though Pushkin heads the list of those writers who made the literature
        \\of their country world-famous, he was still a romanticist, in the
        \\universal literary fashion of his day. However, he already gave strong
        \\indication of the peculiarly Russian genius for naturalness or
        \\realism, and was a true Russian in his simplicity of style. In no
        \\sense an innovator, but taking the cue for his poetry from Byron and
        \\for his prose from the romanticism current at that period, he was not
        \\in advance of his age. He had a revolutionary streak in his nature, as
        \\his _Ode to Liberty_ and other bits of verse and his intimacy with the
        \\Decembrist rebels show. But his youthful fire soon died down, and he
        \\found it possible to accommodate himself to the life of a Russian high
        \\functionary and courtier under the severe despot Nicholas I, though,
        \\to be sure, he always hated that life. For all his flirting with
        \\revolutionarism, he never displayed great originality or depth of
        \\thought. He was simply an extraordinarily gifted author, a perfect
        \\versifier, a wondrous lyrist, and a delicious raconteur, endowed with
        \\a grace, ease and power of expression that delighted even the exacting
        \\artistic sense of Turgenev. To him aptly applies the dictum of
        \\Socrates: "Not by wisdom do the poets write poetry, but by a sort of
        \\genius and inspiration." I do not mean to convey that as a thinker
        \\Pushkin is to be despised. Nevertheless, it is true that he would
        \\occupy a lower position in literature did his reputation depend upon
        \\his contributions to thought and not upon his value as an artist.
    ;
    try tokenizer.train(input, 256 + 128);

    // Encode input text to token ids
    const encoded = try tokenizer.encode(input);
    // Decode back to text bytes
    const decoded = try tokenizer.decode(encoded);
    std.debug.print("{s}\n", .{decoded});

    try tokenizer.save("zbpe");
}

const std = @import("std");
const lib = @import("zbpe_lib");
