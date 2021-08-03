--------------------------------------
-- @file dnf.lua
-- @brief handle dnf 
-- @author yingx
-- @date 2021-08-15
--------------------------------------

local str = require "str"

local op = {
    AND = 'AND',
    OR = 'OR',
    IN = 'IN',
    NOT = 'NOT',
    SEP = ';',
    EOF = 'EOF',
    ZERO = 'Z',
    SPACE = ' ',
}

-- age:3
local function Term(key, value)
    local t = {
        key = key,
        value = value,
    }
    return t
end

-- age:3 in
local function Assignment(relation, term)
    local a = {
        relation = relation,
        term = term,
    }
    return a
end

local function Conjunction(dnf)
    local c = {
        id = 0,
        dnf = dnf,
        size = 0,
        assigns = {},
    }
    return c
end

local function pushAssign(conj, assign)
    table.insert(conj.assigns, assign)
end

local function setId(conj, id)
    conj.id = id
end

-- con ==> age IN 3;4 AND state NOT NY
local function parseConjunction(con)
    local conj = Conjunction(con)
    local assigns = str.split(con, op.AND)
    for i, assign in ipairs(assigns) do
        local t = str.trim(assign)
        local elements = str.split(t, op.IN)
        -- t ===> age IN 3;4
        if #elements == 2 then
            local key = str.trim(elements[1])
            local relation = op.IN
            local values = str.split(elements[2], op.SEP)
            for j, v in ipairs(values) do
                local term = Term(key, str.trim(v))
                local assignment = Assignment(relation, term)
                pushAssign(conj, assignment)
            end
            conj.size = conj.size + 1
        else
            -- t ===> state NOT NY
            elements = str.split(t, op.NOT)
            if #elements == 2 then
                local key = str.trim(elements[1])
                local relation = op.NOT
                local values = str.split(elements[2], op.SEP)
                for j, v in ipairs(values) do
                    local term = Term(key, str.trim(v))
                    local assignment = Assignment(relation, term)
                    pushAssign(conj, assignment)
                end
            end
        end
    end
    return conj
end
    
-- age IN 3;4 AND state NOT NY OR state IN CA AND gender IN M 
local function buildTwoLevelInvertedIndex(dnf, id, doc_inverted_index, id_map, conj_inverted_index)
    print("doc,", id, ":", dnf)
    if #dnf == 0 then
        return
    end
    local conjs = str.split(dnf, op.OR)
    for i, conj in ipairs(conjs) do
        local c = str.trim(conj)
        -- c ==> age IN 3;4 AND state NOT NY
        if id_map[c] == nil then
            local con_id = (id_map["MAX_ID"] or 0) + 1
            id_map["MAX_ID"] = con_id
            id_map[c] = con_id
            local conjunction = parseConjunction(c)
            setId(conjunction, con_id)
            for j, a in ipairs(conjunction.assigns) do
                local key_value = a.term.key .. "_" .. a.term.value
                local conj_size = tostring(conjunction.size)
                conj_inverted_index["MAX_ID"] = conj_inverted_index["MAX_ID"] or 0
                conj_inverted_index["MAX_ID"] = (conj_inverted_index["MAX_ID"] >= conjunction.size) and conj_inverted_index["MAX_ID"] or conjunction.size
                conj_inverted_index[conj_size] = conj_inverted_index[conj_size] or {}
                conj_inverted_index[conj_size].map = conj_inverted_index[conj_size].map or {}
                conj_inverted_index[conj_size].array = conj_inverted_index[conj_size].array or {}
                if not conj_inverted_index[conj_size].map[key_value] then
                    conj_inverted_index[conj_size].map[key_value] = 1
                    conj_inverted_index[conj_size].array[key_value] = {}
                    table.insert(conj_inverted_index[conj_size].array[key_value], {
                        id = con_id,
                        relation = a.relation,
                    })
                else
                    conj_inverted_index[conj_size].map[key_value] = conj_inverted_index[conj_size].map[key_value] + 1
                    table.insert(conj_inverted_index[conj_size].array[key_value], {
                        id = con_id,
                        relation = a.relation,
                    })
                end
                if conjunction.size == 0 then
                    local conid_in = con_id .. "_" .. op.IN
                    if not conj_inverted_index[conj_size].map[op.ZERO] then
                        conj_inverted_index[conj_size].map[op.ZERO] = 1
                        conj_inverted_index[conj_size].map[conid_in] = 1
                        conj_inverted_index[conj_size].array[op.ZERO] = {}
                        table.insert(conj_inverted_index[conj_size].array[op.ZERO], {
                            id = con_id,
                            relation = op.IN,
                        })
                    else
                        if not conj_inverted_index[conj_size].map[conid_in] then
                            conj_inverted_index[conj_size].map[op.ZERO] = conj_inverted_index[conj_size].map[op.ZERO] + 1
                            table.insert(conj_inverted_index[conj_size].array[op.ZERO], {
                                id = con_id,
                                relation = a.relation,
                            })
                        end
                    end
                end
            end
        end
        doc_inverted_index[id_map[c]] = doc_inverted_index[id_map[c]] or {}
        table.insert(doc_inverted_index[id_map[c]], id)
    end
end
    
local function Plist(key, value, conid_relations)
    local a = {
        key = key,
        value = value,
        conid_relations = conid_relations,
        size = #conid_relations,
        current_idx = 1,
        current_entry_id = conid_relations[1].id,
        current_entry_relation = conid_relations[1].relation,
    }
    return a
end

local function skipToNextId(plist, nextid, defaultid)
    local skip_flag = false
    if plist.current_idx <= plist.size then
        for idx = plist.current_idx, plist.size, 1 do
            if plist.conid_relations[idx].id >= nextid then
                plist.current_idx = idx
                plist.current_entry_id = plist.conid_relations[idx].id
                plist.current_entry_relation = plist.conid_relations[idx].relation
                skip_flag = true
                break
            end
        end
    end
    if not skip_flag then
        plist.current_idx = op.EOF
        plist.current_entry_id = defaultid
    end
end

local function sortPlistByCurrentEntries(plists)
    local top_key = {}
    local top_plist = {}
    local tail_plist = {}

    table.sort(plists, function(a, b)
        if a.current_entry_id == b.current_entry_id then
            return (a.current_entry_relation == op.NOT)
        else
            return (a.current_entry_id < b.current_entry_id)
        end
    end)

    for i, v in ipairs(plists) do
        if not top_key[v.key] then
            top_key[v.key] = 1
            table.insert(top_plist, v)
        else
            table.insert(tail_plist, v)
        end
    end

    for i, v in ipairs(tail_plist) do
        table.insert(top_plist, v)
    end

    return top_plist
end

local function retrievalConjunctions(query, con_id_map, conj_inverted_index)
    print(query)
    local fit_cons = {}
    -- query ==> age IN 3 AND state IN CA AND gender IN M
    local q = str.trim(query)
    local conjunction = parseConjunction(query)
    if #(conjunction.assigns) == 0 then
        return fit_cons
    end

    local size = math.min(conj_inverted_index["MAX_ID"], conjunction.size)
    for k = size, 0, -1 do
        local plists = {}
        local key = tostring(k)

        for j, a in ipairs(conjunction.assigns) do
            local key_value = a.term.key .. "_" .. a.term.value
            if conj_inverted_index[key].array[key_value] then
                local value = conj_inverted_index[key].array[key_value]
                local plist = Plist(a.term.key, a.term.value, value)
                table.insert(plists, plist)
            end
        end
        plists = sortPlistByCurrentEntries(plists)
        if k == 0 then
            k = 1
        end
        if #plists >= k then
            local NextId = 1
            while plists[k].current_idx ~= op.EOF do

                plists = sortPlistByCurrentEntries(plists)
                if plists[1].current_entry_id == plists[k].current_entry_id then
                    local skip = false
                    if plists[1].current_entry_relation == op.NOT then
                        local RejectId = plists[1].current_entry_id
                        for l = k, #plists, 1 do
                            if plists[l].current_entry_id == RejectId then
                                skipToNextId(plists[l], RejectId + 1, con_id_map["MAX_ID"])
                            else
                                break
                            end
                        end
                        skip = true
                    else
                        table.insert(fit_cons, plists[k].current_entry_id)
                    end
                    if not skip then
                        NextId = plists[k].current_entry_id + 1
                        for l = 1, k, 1 do
                            skipToNextId(plists[l], NextId, con_id_map["MAX_ID"])
                        end
                    end
                else
                    NextId = plists[k].current_entry_id
                    for l = 1, k, 1 do
                        skipToNextId(plists[l], NextId, con_id_map["MAX_ID"])
                    end
                end
            end
        end
    end

    return fit_cons
end

local function retrievalDocs(cons, doc_inverted_index)
    local fit_docs = {}
    local fit_map = {}
    for i, c in ipairs(cons) do
        for j, v in ipairs(doc_inverted_index[c]) do
            if not fit_map[v] then
                fit_map[v] = 1
                table.insert(fit_docs,  v)
            end
        end
    end
    table.sort(fit_docs)
    return fit_docs
end
    
local function main()
    local doc_inverted_index = {}
    local id_map = {}
    local conj_inverted_index = {}

    buildTwoLevelInvertedIndex(' age IN 3 AND state IN NY OR state IN CA AND gender IN M','doc1', doc_inverted_index, id_map, conj_inverted_index)    
    buildTwoLevelInvertedIndex(' age IN 3 AND gender IN F OR state NOT CA;NY','doc2', doc_inverted_index, id_map, conj_inverted_index)    
    buildTwoLevelInvertedIndex(' age IN 3 AND gender IN M AND state NOT CA OR state IN CA AND gender IN F','doc3', doc_inverted_index, id_map, conj_inverted_index)    
    buildTwoLevelInvertedIndex(' age IN 3;4  OR state IN CA AND gender IN M','doc4', doc_inverted_index, id_map, conj_inverted_index)    
    buildTwoLevelInvertedIndex(' state NOT CA;NY  OR age IN 3;4','doc5', doc_inverted_index, id_map, conj_inverted_index)    
    buildTwoLevelInvertedIndex(' state NOT CA;NY  OR age IN 3 AND state IN NY OR state IN CA AND gender IN M','doc6', doc_inverted_index, id_map, conj_inverted_index)    
    buildTwoLevelInvertedIndex(' age IN 3 AND state IN NY OR state IN CA AND gender IN F','doc7',doc_inverted_index, id_map, conj_inverted_index)    

    local fit_conjunctions = retrievalConjunctions('age IN 3 AND state IN CA AND gender IN M', id_map, conj_inverted_index)
    local fit_docs = retrievalDocs(fit_conjunctions, doc_inverted_index)
    for i, v in ipairs(fit_docs) do
        print("result:", v)
    end
end

main()

