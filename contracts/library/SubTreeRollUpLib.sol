pragma solidity >= 0.6.0;

import { RollUpLib } from "./RollUpLib.sol";
import { Hasher, Tree, SplitRollUp, OPRU } from "./Types.sol";

/**
 * @author Wilson Beam <wilsonbeam@protonmail.com>
 * @title Append-only usage merkle tree roll up library
 */
library SubTreeRollUpLib {
    using RollUpLib for Hasher;
    using RollUpLib for bytes32;

    function rollUpSubTree(
        Hasher memory self,
        uint startingRoot,
        uint index,
        uint subTreeDepth,
        uint[] memory leaves,
        uint[] memory subTreeSiblings
    ) internal pure returns (uint newRoot) {
        require(index % (1 << subTreeDepth) == 0, "Can't merge a subTree");
        require(_emptySubTreeProof(self, startingRoot, index, subTreeDepth, subTreeSiblings), "Can't merge a sub tree");
        uint nextIndex = index;
        uint[][] memory subTrees = splitToSubTrees(leaves, subTreeDepth);
        uint[] memory nextSiblings = subTreeSiblings;
        for(uint i = 0; i < subTrees.length; i++) {
            (newRoot, nextIndex, nextSiblings) = _appendSubTree(
                self,
                nextIndex,
                subTreeDepth,
                subTrees[i],
                nextSiblings
            );
        }
    }

    function newSubTreeOPRU(
        uint startingRoot,
        uint startingIndex,
        uint resultRoot,
        uint subTreeDepth,
        uint[] memory leaves
    ) internal pure returns (OPRU memory opru) {
        uint subTreeSize = 1 << subTreeDepth;
        opru.start.root = startingRoot;
        opru.start.index = startingIndex;
        opru.result.root = resultRoot;
        opru.result.index = startingIndex + subTreeSize*((leaves.length / subTreeSize) + (leaves.length % subTreeSize == 0 ? 0 : 1));
        uint[][] memory subTrees = splitToSubTrees(leaves, subTreeDepth);
        opru.mergedLeaves = merge(bytes32(0), subTrees);
    }

    function init(
        SplitRollUp storage self,
        uint startingRoot,
        uint index
    ) internal {
        self.start.root = startingRoot;
        self.result.root = startingRoot;
        self.start.index = index;
        self.result.index = index;
        self.mergedLeaves = bytes32(0);
    }

    /**
     * @dev It verifies the initial sibling only once and then store the data on chain.
     *      This is usually appropriate for expensive hash functions like MiMC or Poseidon.
     */
    function initWithSiblings(
        SplitRollUp storage self,
        Hasher memory hasher,
        uint startingRoot,
        uint index,
        uint subTreeDepth,
        uint[] memory subTreeSiblings
    ) internal {
        require(_emptySubTreeProof(hasher, startingRoot, index, subTreeDepth, subTreeSiblings), "Can't merge a subTree");
        self.start.root = startingRoot;
        self.result.root = startingRoot;
        self.start.index = index;
        self.result.index = index;
        self.mergedLeaves = bytes32(0);
        self.siblings = subTreeSiblings;
    }
    /**
     * @dev Construct a sub tree and insert into the merkle tree using the
     *      calldata provided sibling data. This is usually appropriate for
     *      keccak or other cheap hash functions.
     * @param self The SplitRollUp to update
     * @param leaves Items to append to the tree.
     */
    function update(
        SplitRollUp storage self,
        Hasher memory hasher,
        uint subTreeDepth,
        uint[] memory subTreeSiblings,
        uint[] memory leaves
    ) internal {
        require(
            _emptySubTreeProof(
                hasher,
                self.result.root,
                self.result.index,
                subTreeDepth,
                subTreeSiblings
            ),
            "Can't merge a subTree"
        );
        uint[] memory nextSiblings = subTreeSiblings;
        uint nextIndex = self.result.index;
        uint[][] memory subTrees = splitToSubTrees(leaves, subTreeDepth);
        uint newRoot;
        for(uint i = 0; i < subTrees.length; i++) {
            (newRoot, nextIndex, nextSiblings) = _appendSubTree(
                hasher,
                nextIndex,
                subTreeDepth,
                subTrees[i],
                nextSiblings
            );
        }
        self.result.root = newRoot;
        self.result.index = nextIndex;
        self.mergedLeaves = merge(self.mergedLeaves, subTrees);
    }

    /**
     * @dev Construct a sub tree and insert into the merkle tree using the on-chain sibling data.
     *      You can use this function when only you started the SplitRollUp using
     *      initSubTreeRollUpWithSiblings()
     * @param self The SplitRollUp to update
     * @param leaves Items to append to the tree.
     */
    function update(
        SplitRollUp storage self,
        Hasher memory hasher,
        uint subTreeDepth,
        uint[] memory leaves
    ) internal {
        uint nextIndex = self.result.index;
        uint[] memory nextSiblings = self.siblings;
        uint[][] memory subTrees = splitToSubTrees(leaves, subTreeDepth);
        uint newRoot;
        for(uint i = 0; i < subTrees.length; i++) {
            (newRoot, nextIndex, nextSiblings) = _appendSubTree(
                hasher,
                nextIndex,
                subTreeDepth,
                subTrees[i],
                nextSiblings
            );
        }
        self.result.root = newRoot;
        self.result.index = nextIndex;
        self.mergedLeaves = merge(self.mergedLeaves, subTrees);
        for(uint i = 0; i < nextSiblings.length; i++) {
            self.siblings[i] = nextSiblings[i];
        }
    }

    function splitToSubTrees(
        uint[] memory leaves,
        uint subTreeDepth
    ) internal pure returns (uint[][] memory subTrees) {
        uint subTreeSize = 1 << subTreeDepth;
        uint numOfSubTrees = (leaves.length / subTreeSize) + (leaves.length % subTreeSize == 0 ? 0 : 1);
        subTrees = new uint[][](numOfSubTrees);
        for (uint i = 0; i < numOfSubTrees; i++) {
            subTrees[i] = new uint[](subTreeSize);
        }
        uint index = 0;
        uint subTreeIndex = 0;
        for(uint i = 0; i < leaves.length; i++) {
            subTrees[subTreeIndex][index] = leaves[i];
            if(index < subTreeSize - 1) {
                index += 1;
            } else {
                index = 0;
                subTreeIndex += 1;
            }
        }
    }

    function verify(
        SplitRollUp memory self,
        OPRU memory opru
    ) internal pure returns (bool) {
        return RollUpLib.verify(self, opru);
    }

    function merge(bytes32 base, uint subTreeDepth, bytes32[] memory leaves) internal pure returns (bytes32) {
        uint[] memory uintLeaves;
        assembly {
            uintLeaves := leaves
        }
        return merge(base, subTreeDepth, uintLeaves);
    }

    function merge(bytes32 base, uint subTreeDepth, uint[] memory leaves) internal pure returns (bytes32) {
        uint[][] memory subTrees = splitToSubTrees(leaves, subTreeDepth);
        return merge(base, subTrees);
    }

    function merge(bytes32 base, uint[][] memory subTrees) internal pure returns (bytes32) {
        bytes32[] memory subTreeHashes = new bytes32[](subTrees.length);
        for(uint i = 0; i < subTrees.length; i++) {
            subTreeHashes[i] = keccak256(abi.encodePacked(subTrees[i]));
        }
        return RollUpLib.merge(base, subTreeHashes);
    }

    function mergeResult(uint[] memory leaves, uint subTreeDepth) internal pure returns (
        bytes32 mergedAsIndividuals,
        bytes32 mergedAsSubTrees
    )
    {
        return (
            RollUpLib.merge(bytes32(0), leaves),
            merge(bytes32(0), subTreeDepth, leaves)
        );
    }

    /**
     * @param siblings If the merkle tree depth is "D" and the subTree's
     *          depth is "d", the length of the siblings should be "D - d".
     */
    function _emptySubTreeProof(
        Hasher memory self,
        uint root,
        uint index,
        uint subTreeDepth,
        uint[] memory siblings
    ) internal pure returns (bool) {
        uint subTreePath = index >> subTreeDepth;
        uint path = subTreePath;
        for(uint i = 0; i < siblings.length; i++) {
            if(path & 1 == 0) {
                // Right sibling should be a prehashed zero
                if(siblings[i] != self.preHashedZero[i + subTreeDepth]) return false;
            } else {
                // Left sibling should not be a prehashed zero
                if(siblings[i] == self.preHashedZero[i + subTreeDepth]) return false;
            }
            path >>= 1;
        }
        return self.merkleProof(root, self.preHashedZero[subTreeDepth], subTreePath, siblings);
    }

    function _appendSubTree(
        Hasher memory self,
        uint index,
        uint subTreeDepth,
        uint[] memory subTreeHashes,
        uint[] memory siblings
    ) internal pure returns(
        uint nextRoot,
        uint nextIndex,
        uint[] memory nextSiblings
    ) {
        nextSiblings = new uint[](siblings.length);
        uint subTreePath = index >> subTreeDepth;
        uint path = subTreePath;
        uint node = _subTreeRoot(self, subTreeDepth, subTreeHashes);
        for (uint i = 0; i < siblings.length; i++) {
            if (path & 1 == 0) {
                // right empty sibling
                nextSiblings[i] = node; // current node will be the next merkle proof's left sibling
                node = self.parentOf(node, self.preHashedZero[i + subTreeDepth]);
            } else {
                // left sibling
                nextSiblings[i] = siblings[i]; // keep current sibling
                node = self.parentOf(siblings[i], node);
            }
            path >>= 1;
        }
        nextRoot = node;
        nextIndex = index + (1 << subTreeDepth);
    }

    function _subTreeRoot(
        Hasher memory self,
        uint subTreeDepth,
        uint[] memory leaves
    ) internal pure returns (uint) {
        /// Example of a sub tree with depth 3
        ///                      1
        ///          10                       11
        ///    100        101         110           [111]
        /// 1000 1001  1010 1011   1100 [1101]  [1110] [1111]
        ///   o   o     o    o       o    x       x       x
        ///
        /// whereEmptyNodeStart (1101) = leaves.length + tree_size
        /// []: nodes that we can use the pre hashed zeroes
        ///
        /// * ([1101] << 0) is gte than (1101) => we can use the pre hashed zeroes
        /// * ([1110] << 0) is gte than (1101) => we can use the pre hashed zeroes
        /// * ([1111] << 0) is gte than (1101) => we can use pre hashed zeroes
        /// * ([111] << 1) is gte than (1101) => we can use pre hashed zeroes
        /// * (11 << 2) is less than (1101) => we cannot use pre hashed zeroes
        /// * (1 << 3) is less than (1101) => we cannot use pre hashed zeroes

        uint treeSize = 1 << subTreeDepth;
        require(leaves.length <= treeSize, "Overflowed");

        uint[] memory nodes = new uint[](treeSize << 1); /// we'll not use nodes[0]
        uint emptyNode = treeSize + (leaves.length - 1); /// we do not hash if we can use pre hashed zeroes
        uint leftMostOfTheFloor = treeSize;

        /// From the bottom to the top
        for(uint level = 0; level <= subTreeDepth; level++) {
            /// From the right to the left
            for(
                uint nodeIndex = (treeSize << 1) - 1;
                nodeIndex >= leftMostOfTheFloor;
                nodeIndex--
            )
            {
                if (nodeIndex <= emptyNode) {
                    /// This node is not an empty node
                    if (level == 0) {
                        /// Leaf node
                        nodes[nodeIndex] = leaves[nodeIndex - treeSize];
                    } else {
                        /// Parent node
                        uint leftChild = nodeIndex << 1;
                        uint rightChild = leftChild + 1;
                        nodes[nodeIndex] = self.parentOf(nodes[leftChild], nodes[rightChild]);
                    }
                } else {
                    /// Use pre hashed
                    nodes[nodeIndex] = self.preHashedZero[level];
                }
            }
            leftMostOfTheFloor >>= 1;
            emptyNode >>= 1;
        }
    }
}
