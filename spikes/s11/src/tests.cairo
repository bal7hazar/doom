// SPDX-License-Identifier: Apache-2.0
// Generated independently by vectors.py (hashlib), not by Cairo.
use super::hash9;

#[test]
fn test_empty() {
    let input = array![];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0x9e5ce268, 0xde011fa3, 0xd7af211a, 0xd56729c6, 0x7d88bcf1, 0x1b98c507, 0x99e1bb44,
            0xf0612020,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x61202099e1b9461b98c5077d88bcf1d56729c6d7af211ade011fa39e5ce24a,
        'reduction all bits',
    );
}

#[test]
fn test_zero() {
    let input = array![0x0];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0x18012e91, 0xa597c61f, 0xc409aa36, 0xdcbf0e6, 0x2ae98981, 0xd1e28755, 0xf61ed861,
            0x64c17c10,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x4c17c10f61ed795d1e287552ae989810dcbf0e6c409aa36a597c61f18012e85,
        'reduction all bits',
    );
}

#[test]
fn test_max72() {
    let input = array![0xffffffffffffffffff];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0x991581e4, 0xf0104cc5, 0x5e59431, 0xe7e0d318, 0xa6306fb9, 0x13bbb271, 0x981add71,
            0x5575b8f8,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x575b8f8981adcc713bbb271a6306fb9e7e0d31805e59431f0104cc5991581da,
        'reduction all bits',
    );
}

#[test]
fn test_endian() {
    let input = array![0x10203040506070809];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0x2175fb6b, 0x55e3dc83, 0x5a6d0850, 0x4cdf3921, 0x7c00ca3f, 0x99eba008, 0x6578f9c7,
            0xfea54f03,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x6a54f036578f7b899eba0087c00ca3f4cdf39215a6d085055e3dc832175fb4c,
        'reduction all bits',
    );
}

#[test]
fn test_trailing_zero() {
    let input = array![0x1, 0x0];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0xe006e5a4, 0x826ecfc2, 0x8178811c, 0xadb4b8dd, 0x17e97927, 0xa0e4a8d6, 0xd70043be,
            0xa6eaa66d,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x6eaa66dd700426aa0e4a8d617e97927adb4b8dd8178811c826ecfc2e006e590,
        'reduction all bits',
    );
}

#[test]
fn test_length_3() {
    let input = array![0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0x657dc10, 0x8193fb86, 0xe27b9ef0, 0x262fdea8, 0xa3e747ea, 0xfb3fdaab, 0xa997a46f,
            0x1f98f764,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x798f764a997a43cfb3fdaaba3e747ea262fdea8e27b9ef08193fb860657dc0d,
        'reduction all bits',
    );
}

#[test]
fn test_length_4() {
    let input = array![
        0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1, 0xfffffcf9f6f3f0edea,
    ];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0xa2996419, 0x203f2e0, 0x398cb7c3, 0x924ae91e, 0x75c2d4cd, 0xd21a9e07, 0x1f36d4cd,
            0x56ea182d,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x6ea182d1f36d423d21a9e0775c2d4cd924ae91e398cb7c30203f2e0a299640f,
        'reduction all bits',
    );
}

#[test]
fn test_length_7() {
    let input = array![
        0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1, 0xfffffcf9f6f3f0edea,
        0xfffffbf7f3efebe7e3, 0xfffffaf5f0ebe6e1dc, 0xfffff9f3ede7e1dbd5,
    ];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0x90efe57c, 0x29cfa20e, 0x1ab9c08f, 0x26b46956, 0xecad7746, 0x3731c78e, 0x6959cd9f,
            0x9bf03387,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x3f033876959cc5c3731c78eecad774626b469561ab9c08f29cfa20e90efe569,
        'reduction all bits',
    );
}

#[test]
fn test_length_8() {
    let input = array![
        0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1, 0xfffffcf9f6f3f0edea,
        0xfffffbf7f3efebe7e3, 0xfffffaf5f0ebe6e1dc, 0xfffff9f3ede7e1dbd5, 0xfffff8f1eae3dcd5ce,
    ];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0x8f69dc10, 0xf8fb7051, 0xb47daa17, 0x787c7b68, 0x5ca41a24, 0x6ba7b49e, 0xdb64c9a1,
            0x99365c6a,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x1365c6adb64c85e6ba7b49e5ca41a24787c7b68b47daa17f8fb70518f69dbfd,
        'reduction all bits',
    );
}

#[test]
fn test_length_31() {
    let input = array![
        0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1, 0xfffffcf9f6f3f0edea,
        0xfffffbf7f3efebe7e3, 0xfffffaf5f0ebe6e1dc, 0xfffff9f3ede7e1dbd5, 0xfffff8f1eae3dcd5ce,
        0xfffff7efe7dfd7cfc7, 0xfffff6ede4dbd2c9c0, 0xfffff5ebe1d7cdc3b9, 0xfffff4e9ded3c8bdb2,
        0xfffff3e7dbcfc3b7ab, 0xfffff2e5d8cbbeb1a4, 0xfffff1e3d5c7b9ab9d, 0xfffff0e1d2c3b4a596,
        0xffffefdfcfbfaf9f8f, 0xffffeeddccbbaa9988, 0xffffeddbc9b7a59381, 0xffffecd9c6b3a08d7a,
        0xffffebd7c3af9b8773, 0xffffead5c0ab96816c, 0xffffe9d3bda7917b65, 0xffffe8d1baa38c755e,
        0xffffe7cfb79f876f57, 0xffffe6cdb49b826950, 0xffffe5cbb1977d6349, 0xffffe4c9ae93785d42,
        0xffffe3c7ab8f73573b, 0xffffe2c5a88b6e5134, 0xffffe1c3a587694b2d,
    ];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0x36f16c6e, 0x68246aa4, 0xd5785ee8, 0x175bf7d6, 0xbccb9f39, 0x4c03f03d, 0x38745e5,
            0x63be0582,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x3be0582038745194c03f03dbccb9f39175bf7d6d5785ee868246aa436f16c62,
        'reduction all bits',
    );
}

#[test]
fn test_length_32() {
    let input = array![
        0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1, 0xfffffcf9f6f3f0edea,
        0xfffffbf7f3efebe7e3, 0xfffffaf5f0ebe6e1dc, 0xfffff9f3ede7e1dbd5, 0xfffff8f1eae3dcd5ce,
        0xfffff7efe7dfd7cfc7, 0xfffff6ede4dbd2c9c0, 0xfffff5ebe1d7cdc3b9, 0xfffff4e9ded3c8bdb2,
        0xfffff3e7dbcfc3b7ab, 0xfffff2e5d8cbbeb1a4, 0xfffff1e3d5c7b9ab9d, 0xfffff0e1d2c3b4a596,
        0xffffefdfcfbfaf9f8f, 0xffffeeddccbbaa9988, 0xffffeddbc9b7a59381, 0xffffecd9c6b3a08d7a,
        0xffffebd7c3af9b8773, 0xffffead5c0ab96816c, 0xffffe9d3bda7917b65, 0xffffe8d1baa38c755e,
        0xffffe7cfb79f876f57, 0xffffe6cdb49b826950, 0xffffe5cbb1977d6349, 0xffffe4c9ae93785d42,
        0xffffe3c7ab8f73573b, 0xffffe2c5a88b6e5134, 0xffffe1c3a587694b2d, 0xffffe0c1a283644526,
    ];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0xb32b8582, 0x67df4970, 0xe51e2bd5, 0x352244d8, 0xf192d361, 0x5ca5321, 0x490dee5a,
            0x3c470570,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x4470570490dede305ca5321f192d361352244d8e51e2bd567df4970b32b857b,
        'reduction all bits',
    );
}

#[test]
fn test_length_33() {
    let input = array![
        0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1, 0xfffffcf9f6f3f0edea,
        0xfffffbf7f3efebe7e3, 0xfffffaf5f0ebe6e1dc, 0xfffff9f3ede7e1dbd5, 0xfffff8f1eae3dcd5ce,
        0xfffff7efe7dfd7cfc7, 0xfffff6ede4dbd2c9c0, 0xfffff5ebe1d7cdc3b9, 0xfffff4e9ded3c8bdb2,
        0xfffff3e7dbcfc3b7ab, 0xfffff2e5d8cbbeb1a4, 0xfffff1e3d5c7b9ab9d, 0xfffff0e1d2c3b4a596,
        0xffffefdfcfbfaf9f8f, 0xffffeeddccbbaa9988, 0xffffeddbc9b7a59381, 0xffffecd9c6b3a08d7a,
        0xffffebd7c3af9b8773, 0xffffead5c0ab96816c, 0xffffe9d3bda7917b65, 0xffffe8d1baa38c755e,
        0xffffe7cfb79f876f57, 0xffffe6cdb49b826950, 0xffffe5cbb1977d6349, 0xffffe4c9ae93785d42,
        0xffffe3c7ab8f73573b, 0xffffe2c5a88b6e5134, 0xffffe1c3a587694b2d, 0xffffe0c1a283644526,
        0xffffdfbf9f7f5f3f1f,
    ];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0x1c538f02, 0x29fe79a3, 0x1c18d5eb, 0xff23c815, 0x5f2998d3, 0x14cc2a82, 0xf74807f4,
            0xd2fa02be,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x2fa02bef748063a14cc2a825f2998d3ff23c8151c18d5eb29fe79a31c538ee8,
        'reduction all bits',
    );
}

#[test]
fn test_length_63() {
    let input = array![
        0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1, 0xfffffcf9f6f3f0edea,
        0xfffffbf7f3efebe7e3, 0xfffffaf5f0ebe6e1dc, 0xfffff9f3ede7e1dbd5, 0xfffff8f1eae3dcd5ce,
        0xfffff7efe7dfd7cfc7, 0xfffff6ede4dbd2c9c0, 0xfffff5ebe1d7cdc3b9, 0xfffff4e9ded3c8bdb2,
        0xfffff3e7dbcfc3b7ab, 0xfffff2e5d8cbbeb1a4, 0xfffff1e3d5c7b9ab9d, 0xfffff0e1d2c3b4a596,
        0xffffefdfcfbfaf9f8f, 0xffffeeddccbbaa9988, 0xffffeddbc9b7a59381, 0xffffecd9c6b3a08d7a,
        0xffffebd7c3af9b8773, 0xffffead5c0ab96816c, 0xffffe9d3bda7917b65, 0xffffe8d1baa38c755e,
        0xffffe7cfb79f876f57, 0xffffe6cdb49b826950, 0xffffe5cbb1977d6349, 0xffffe4c9ae93785d42,
        0xffffe3c7ab8f73573b, 0xffffe2c5a88b6e5134, 0xffffe1c3a587694b2d, 0xffffe0c1a283644526,
        0xffffdfbf9f7f5f3f1f, 0xffffdebd9c7b5a3918, 0xffffddbb9977553311, 0xffffdcb99673502d0a,
        0xffffdbb7936f4b2703, 0xffffdab5906b4620fc, 0xffffd9b38d67411af5, 0xffffd8b18a633c14ee,
        0xffffd7af875f370ee7, 0xffffd6ad845b3208e0, 0xffffd5ab81572d02d9, 0xffffd4a97e5327fcd2,
        0xffffd3a77b4f22f6cb, 0xffffd2a5784b1df0c4, 0xffffd1a3754718eabd, 0xffffd0a1724313e4b6,
        0xffffcf9f6f3f0edeaf, 0xffffce9d6c3b09d8a8, 0xffffcd9b693704d2a1, 0xffffcc996632ffcc9a,
        0xffffcb97632efac693, 0xffffca95602af5c08c, 0xffffc9935d26f0ba85, 0xffffc8915a22ebb47e,
        0xffffc78f571ee6ae77, 0xffffc68d541ae1a870, 0xffffc58b5116dca269, 0xffffc4894e12d79c62,
        0xffffc3874b0ed2965b, 0xffffc285480acd9054, 0xffffc1834506c88a4d,
    ];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0x83d4340f, 0x78419058, 0xd7e3e1bc, 0xbfdd8a17, 0x80db4774, 0x60e52971, 0x2ffd73d3,
            0xc0bafb71,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0xbafb712ffd723b60e5297180db4774bfdd8a17d7e3e1bc7841905883d433f7,
        'reduction all bits',
    );
}

#[test]
fn test_length_64() {
    let input = array![
        0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1, 0xfffffcf9f6f3f0edea,
        0xfffffbf7f3efebe7e3, 0xfffffaf5f0ebe6e1dc, 0xfffff9f3ede7e1dbd5, 0xfffff8f1eae3dcd5ce,
        0xfffff7efe7dfd7cfc7, 0xfffff6ede4dbd2c9c0, 0xfffff5ebe1d7cdc3b9, 0xfffff4e9ded3c8bdb2,
        0xfffff3e7dbcfc3b7ab, 0xfffff2e5d8cbbeb1a4, 0xfffff1e3d5c7b9ab9d, 0xfffff0e1d2c3b4a596,
        0xffffefdfcfbfaf9f8f, 0xffffeeddccbbaa9988, 0xffffeddbc9b7a59381, 0xffffecd9c6b3a08d7a,
        0xffffebd7c3af9b8773, 0xffffead5c0ab96816c, 0xffffe9d3bda7917b65, 0xffffe8d1baa38c755e,
        0xffffe7cfb79f876f57, 0xffffe6cdb49b826950, 0xffffe5cbb1977d6349, 0xffffe4c9ae93785d42,
        0xffffe3c7ab8f73573b, 0xffffe2c5a88b6e5134, 0xffffe1c3a587694b2d, 0xffffe0c1a283644526,
        0xffffdfbf9f7f5f3f1f, 0xffffdebd9c7b5a3918, 0xffffddbb9977553311, 0xffffdcb99673502d0a,
        0xffffdbb7936f4b2703, 0xffffdab5906b4620fc, 0xffffd9b38d67411af5, 0xffffd8b18a633c14ee,
        0xffffd7af875f370ee7, 0xffffd6ad845b3208e0, 0xffffd5ab81572d02d9, 0xffffd4a97e5327fcd2,
        0xffffd3a77b4f22f6cb, 0xffffd2a5784b1df0c4, 0xffffd1a3754718eabd, 0xffffd0a1724313e4b6,
        0xffffcf9f6f3f0edeaf, 0xffffce9d6c3b09d8a8, 0xffffcd9b693704d2a1, 0xffffcc996632ffcc9a,
        0xffffcb97632efac693, 0xffffca95602af5c08c, 0xffffc9935d26f0ba85, 0xffffc8915a22ebb47e,
        0xffffc78f571ee6ae77, 0xffffc68d541ae1a870, 0xffffc58b5116dca269, 0xffffc4894e12d79c62,
        0xffffc3874b0ed2965b, 0xffffc285480acd9054, 0xffffc1834506c88a4d, 0xffffc0814202c38446,
    ];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0xed46be3f, 0x42407af4, 0xba531be0, 0xf28ad279, 0xbc9160c2, 0x29edcf10, 0xc2dd4ce2,
            0xaad2355f,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x2d2355fc2dd4b7d29edcf10bc9160c2f28ad279ba531be042407af4ed46be2a,
        'reduction all bits',
    );
}

#[test]
fn test_length_65() {
    let input = array![
        0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1, 0xfffffcf9f6f3f0edea,
        0xfffffbf7f3efebe7e3, 0xfffffaf5f0ebe6e1dc, 0xfffff9f3ede7e1dbd5, 0xfffff8f1eae3dcd5ce,
        0xfffff7efe7dfd7cfc7, 0xfffff6ede4dbd2c9c0, 0xfffff5ebe1d7cdc3b9, 0xfffff4e9ded3c8bdb2,
        0xfffff3e7dbcfc3b7ab, 0xfffff2e5d8cbbeb1a4, 0xfffff1e3d5c7b9ab9d, 0xfffff0e1d2c3b4a596,
        0xffffefdfcfbfaf9f8f, 0xffffeeddccbbaa9988, 0xffffeddbc9b7a59381, 0xffffecd9c6b3a08d7a,
        0xffffebd7c3af9b8773, 0xffffead5c0ab96816c, 0xffffe9d3bda7917b65, 0xffffe8d1baa38c755e,
        0xffffe7cfb79f876f57, 0xffffe6cdb49b826950, 0xffffe5cbb1977d6349, 0xffffe4c9ae93785d42,
        0xffffe3c7ab8f73573b, 0xffffe2c5a88b6e5134, 0xffffe1c3a587694b2d, 0xffffe0c1a283644526,
        0xffffdfbf9f7f5f3f1f, 0xffffdebd9c7b5a3918, 0xffffddbb9977553311, 0xffffdcb99673502d0a,
        0xffffdbb7936f4b2703, 0xffffdab5906b4620fc, 0xffffd9b38d67411af5, 0xffffd8b18a633c14ee,
        0xffffd7af875f370ee7, 0xffffd6ad845b3208e0, 0xffffd5ab81572d02d9, 0xffffd4a97e5327fcd2,
        0xffffd3a77b4f22f6cb, 0xffffd2a5784b1df0c4, 0xffffd1a3754718eabd, 0xffffd0a1724313e4b6,
        0xffffcf9f6f3f0edeaf, 0xffffce9d6c3b09d8a8, 0xffffcd9b693704d2a1, 0xffffcc996632ffcc9a,
        0xffffcb97632efac693, 0xffffca95602af5c08c, 0xffffc9935d26f0ba85, 0xffffc8915a22ebb47e,
        0xffffc78f571ee6ae77, 0xffffc68d541ae1a870, 0xffffc58b5116dca269, 0xffffc4894e12d79c62,
        0xffffc3874b0ed2965b, 0xffffc285480acd9054, 0xffffc1834506c88a4d, 0xffffc0814202c38446,
        0xffffbf7f3efebe7e3f,
    ];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0xd1c9a374, 0xc9cc0ef0, 0x53bf912d, 0x4be66ab5, 0xdd09b34f, 0xe7c94720, 0x16ab1df8,
            0xf6b6ee3b,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x6b6ee3b16ab1bfae7c94720dd09b34f4be66ab553bf912dc9cc0ef0d1c9a356,
        'reduction all bits',
    );
}

#[test]
fn test_length_96() {
    let input = array![
        0xffffffffffffffffff, 0xfffffefdfcfbfaf9f8, 0xfffffdfbf9f7f5f3f1, 0xfffffcf9f6f3f0edea,
        0xfffffbf7f3efebe7e3, 0xfffffaf5f0ebe6e1dc, 0xfffff9f3ede7e1dbd5, 0xfffff8f1eae3dcd5ce,
        0xfffff7efe7dfd7cfc7, 0xfffff6ede4dbd2c9c0, 0xfffff5ebe1d7cdc3b9, 0xfffff4e9ded3c8bdb2,
        0xfffff3e7dbcfc3b7ab, 0xfffff2e5d8cbbeb1a4, 0xfffff1e3d5c7b9ab9d, 0xfffff0e1d2c3b4a596,
        0xffffefdfcfbfaf9f8f, 0xffffeeddccbbaa9988, 0xffffeddbc9b7a59381, 0xffffecd9c6b3a08d7a,
        0xffffebd7c3af9b8773, 0xffffead5c0ab96816c, 0xffffe9d3bda7917b65, 0xffffe8d1baa38c755e,
        0xffffe7cfb79f876f57, 0xffffe6cdb49b826950, 0xffffe5cbb1977d6349, 0xffffe4c9ae93785d42,
        0xffffe3c7ab8f73573b, 0xffffe2c5a88b6e5134, 0xffffe1c3a587694b2d, 0xffffe0c1a283644526,
        0xffffdfbf9f7f5f3f1f, 0xffffdebd9c7b5a3918, 0xffffddbb9977553311, 0xffffdcb99673502d0a,
        0xffffdbb7936f4b2703, 0xffffdab5906b4620fc, 0xffffd9b38d67411af5, 0xffffd8b18a633c14ee,
        0xffffd7af875f370ee7, 0xffffd6ad845b3208e0, 0xffffd5ab81572d02d9, 0xffffd4a97e5327fcd2,
        0xffffd3a77b4f22f6cb, 0xffffd2a5784b1df0c4, 0xffffd1a3754718eabd, 0xffffd0a1724313e4b6,
        0xffffcf9f6f3f0edeaf, 0xffffce9d6c3b09d8a8, 0xffffcd9b693704d2a1, 0xffffcc996632ffcc9a,
        0xffffcb97632efac693, 0xffffca95602af5c08c, 0xffffc9935d26f0ba85, 0xffffc8915a22ebb47e,
        0xffffc78f571ee6ae77, 0xffffc68d541ae1a870, 0xffffc58b5116dca269, 0xffffc4894e12d79c62,
        0xffffc3874b0ed2965b, 0xffffc285480acd9054, 0xffffc1834506c88a4d, 0xffffc0814202c38446,
        0xffffbf7f3efebe7e3f, 0xffffbe7d3bfab97838, 0xffffbd7b38f6b47231, 0xffffbc7935f2af6c2a,
        0xffffbb7732eeaa6623, 0xffffba752feaa5601c, 0xffffb9732ce6a05a15, 0xffffb87129e29b540e,
        0xffffb76f26de964e07, 0xffffb66d23da914800, 0xffffb56b20d68c41f9, 0xffffb4691dd2873bf2,
        0xffffb3671ace8235eb, 0xffffb26517ca7d2fe4, 0xffffb16314c67829dd, 0xffffb06111c27323d6,
        0xffffaf5f0ebe6e1dcf, 0xffffae5d0bba6917c8, 0xffffad5b08b66411c1, 0xffffac5905b25f0bba,
        0xffffab5702ae5a05b3, 0xffffaa54ffaa54ffac, 0xffffa952fca64ff9a5, 0xffffa850f9a24af39e,
        0xffffa74ef69e45ed97, 0xffffa64cf39a40e790, 0xffffa54af0963be189, 0xffffa448ed9236db82,
        0xffffa346ea8e31d57b, 0xffffa244e78a2ccf74, 0xffffa142e48627c96d, 0xffffa040e18222c366,
    ];
    let digest = hash9::digest(input.span()).unwrap();
    assert(
        digest == [
            0xe57841b6, 0x143669b2, 0x6c412bb1, 0x47582272, 0x80d5dfe9, 0x530da89d, 0x5e0c120f,
            0xf55c4f5d,
        ],
        'independent digest',
    );
    assert(
        hash9::reduce(digest) == 0x55c4f5d5e0c1011530da89d80d5dfe9475822726c412bb1143669b2e5784198,
        'reduction all bits',
    );
}

#[test]
fn test_domain_rejected() {
    assert(hash9::hash(array![0x1000000000000000000].span()).is_none(), 'two72 rejected');
    assert(
        hash9::hash(
            array![0x800000000000011000000000000000000000000000000000000000000000000].span(),
        )
            .is_none(),
        'large felt rejected',
    );
}
