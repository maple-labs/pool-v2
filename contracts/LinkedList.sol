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

        // LOOP

        Node memory loopNode = list[head];
        uint256     nodeId   = head;

        // console.log("BEGINNING");
        // console.log("head", head);

        while (true && nodeId > 0) {
            // console.log("");
            // console.log("nodeId         ", nodeId);
            // console.log("loopNode.prevId", loopNode.prevId);
            // console.log("loopNode.nextId", loopNode.nextId);
            // console.log("loopNode.date  ", loopNode.date);
            // console.log("loopNode.date  ", (loopNode.date - 1622400000) * 100 / 1 days);

            nodeId   = loopNode.nextId;
            loopNode = list[loopNode.nextId];
            if (nodeId == 0) break;
        }
        console.log("");

        // LOOP

        Node memory node = Node({prevId: 0, date: value_, nextId: 0});

        // console.log("date", (value_ - 1622400000) * 100 / 1 days);

        nodeId_ = ++nextId;

        // If only item in list, insert as head
        if (totalItems == 0) {
            // console.log("");
            // console.log("inserting as head", nodeId_);
            // // console.log("value_           ", value_);
            // console.log("date             ", (value_ - 1622400000) * 100 / 1 days);

            head          = nodeId_;
            list[nodeId_] = node;

            // LOOP


            loopNode = list[head];
            nodeId   = head;

            // console.log("---------------");
            // console.log("totalItems == 0");
            // console.log("---------------");
            // console.log("head", head);

            while(true) {
                // console.log("");
                // console.log("nodeId         ", nodeId);
                // console.log("loopNode.prevId", loopNode.prevId);
                // console.log("loopNode.nextId", loopNode.nextId);
                // console.log("loopNode.date  ", (loopNode.date - 1622400000) * 100 / 1 days);

                nodeId   = loopNode.nextId;
                loopNode = list[nodeId];
                if (nodeId == 0) break;
            }
            console.log("");

            // LOOP


            totalItems++;
            return nodeId_;
        }

        // Inserting head
        if (existingId_ == 0) {
            // console.log("");
            // console.log("inserting head", nodeId_);
            // // console.log("value_        ", value_);
            // console.log("date          ", (value_ - 1622400000) * 100 / 1 days);

            list[head].prevId = nodeId_;
            node.nextId       = head;
            head              = nodeId_;
            list[nodeId_]     = node;

            // LOOP

            loopNode = list[head];
            nodeId   = head;

            // console.log("----------------");
            // console.log("existingId_ == 0");
            // console.log("----------------");
            // console.log("head", head);

            while(true) {
                // console.log("");
                // console.log("nodeId         ", nodeId);
                // console.log("loopNode.prevId", loopNode.prevId);
                // console.log("loopNode.nextId", loopNode.nextId);
                // console.log("loopNode.date  ", (loopNode.date - 1622400000) * 100 / 1 days);

                nodeId   = loopNode.nextId;
                loopNode = list[nodeId];
                if (nodeId == 0) break;
            }
            console.log("");

            // LOOP

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
            // console.log("cachedNext", cachedNext);
            // console.log("value_    ", value_);
            // console.log("next.date ", next.date);
            console.log("list[cachedNext].date ", (list[cachedNext].date - 1622400000) * 100 / 1 days);
            // console.log("list[prev.nextId].date", (list[prev.nextId].date - 1622400000) * 100 / 1 days);

            // If the previous node wasn't the last on the list
            Node memory next = list[cachedNext];
            // console.log("cachedNext", cachedNext);
            // console.log("value_    ", (value_ - 1622400000) * 100 / 1 days);
            // console.log("next.date ", (next.date - 1622400000) * 100 / 1 days);
            require(value_ <= next.date, "wrong position 2");

            next.prevId = nodeId_;
            node.nextId = cachedNext;

            list[cachedNext] = next;
        }

        totalItems++;
        list[existingId_] = prev;
        list[nodeId_]     = node;

        // LOOP

        loopNode = list[head];
        nodeId   = head;

        // console.log("---");
        // console.log("END");
        // console.log("---");
        // console.log("head", head);

        while(true) {
            // console.log("");
            // console.log("nodeId         ", nodeId);
            // console.log("loopNode.prevId", loopNode.prevId);
            // console.log("loopNode.nextId", loopNode.nextId);
            // console.log("loopNode.date  ", (loopNode.date - 1622400000) * 100 / 1 days);

            nodeId   = loopNode.nextId;
            loopNode = list[nodeId];
            if (nodeId == 0) break;
        }
        console.log("");

        // LOOP
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

        console.log("totalItems", totalItems);

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
