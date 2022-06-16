// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { console } from "../modules/contract-test-utils/contracts/log.sol";

contract DateLinkedList {

    uint256 head;
    uint256 nextId;
    uint256 totalItems;

    mapping (uint256 => Node) list; // nodeId => Node

    struct Node {
        uint256 prevId;
        uint256 date;
        uint256 nextId;
    }

    function insert(uint256 value_, uint256 existingId_) internal returns (uint256 nodeId_) {

        Node memory loopNode = list[head];
        uint256     nodeId   = head;

        while (true && nodeId > 0) {
            nodeId   = loopNode.nextId;
            loopNode = list[loopNode.nextId];
            if (nodeId == 0) break;
        }

        Node memory node = Node({prevId: 0, date: value_, nextId: 0});

        nodeId_ = ++nextId;

        // If only item in list, insert as head
        if (totalItems == 0) {
            head          = nodeId_;
            list[nodeId_] = node;

            totalItems++;
            return nodeId_;
        }

        // Inserting head
        if (existingId_ == 0) {
            list[head].prevId = nodeId_;
            node.nextId       = head;
            head              = nodeId_;
            list[nodeId_]     = node;

            totalItems++;
            return nodeId_;
        }

        Node memory prev = list[existingId_];
        require(value_ >= prev.date, "wrong position 1");

        uint256 cachedNext = prev.nextId;

        // Append value after existing Id
        node.prevId = existingId_;
        prev.nextId = nodeId_;

        if (cachedNext != 0) {
            // If the previous node wasn't the last on the list
            Node memory next = list[cachedNext];
            require(value_ <= next.date, "wrong position 2");

            next.prevId = nodeId_;
            node.nextId = cachedNext;

            list[cachedNext] = next;
        }

        totalItems++;
        list[existingId_] = prev;
        list[nodeId_]     = node;
    }

    function remove(uint256 nodeId) internal {
        // if is head
        if (nodeId == head) {
            uint256 next = list[nodeId].nextId;

            head = next;
            list[next].prevId = 0;
        }

        Node memory current = list[nodeId];
        uint256 next = current.nextId;
        uint256 prev = current.prevId;

        list[next].prevId = prev;
        list[prev].nextId = next;

        delete list[nodeId];
        totalItems--;
    }

    function positionPreceeding(uint256 value_) internal view returns (uint256 pos) {
        uint256 currentId = head;

        Node memory current = list[currentId];

        // The position to insert is the head
        if (value_ <= current.date) return 0;

        while (current.nextId != 0) {
            // Get the next item in the list
            Node memory next = list[current.nextId];

            // If the next date is greater than the value, return currentId as the position preceeding
            if (next.date >= value_) {
                return pos = currentId;
            }

            // Set the current id to the next
            currentId = current.nextId;
            current   = next;
        }
        return currentId;
    }

}
