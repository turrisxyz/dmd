/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Manage flow analysis for constructors.
 *
 * Copyright:   Copyright (C) 1999-2018 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/ctorflow.d, _ctorflow.d)
 * Documentation:  https://dlang.org/phobos/dmd_ctorflow.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/ctorflow.d
 */

module dmd.ctorflow;

import core.stdc.stdio;

import dmd.root.rmem;

enum CSX : ushort
{
    none            = 0,
    this_ctor       = 0x01,     /// called this()
    super_ctor      = 0x02,     /// called super()
    this_           = 0x04,     /// referenced this
    super_          = 0x08,     /// referenced super
    label           = 0x10,     /// seen a label
    return_         = 0x20,     /// seen a return statement
    any_ctor        = 0x40,     /// either this() or super() was called
    halt            = 0x80,     /// assert(0)
    deprecate_18719 = 0x100,    // issue deprecation for Issue 18719 - delete when deprecation period is over
}

/***********
 * Primitive flow analysis for constructors
 */
struct CtorFlow
{
    CSX callSuper;      /// state of calling other constructors

    CSX[] fieldinit;    /// state of field initializations

    void allocFieldinit(size_t dim)
    {
        fieldinit = (cast(CSX*)mem.xcalloc(CSX.sizeof, dim))[0 .. dim];
    }

    void freeFieldinit()
    {
        if (fieldinit.ptr)
            mem.xfree(fieldinit.ptr);
        fieldinit = null;
    }

    CSX[] saveFieldInit()
    {
        CSX[] fi = null;
        if (fieldinit.length) // copy
        {
            const dim = fieldinit.length;
            fi = (cast(CSX*)mem.xmalloc(CSX.sizeof * dim))[0 .. dim];
            fi[] = fieldinit[];
        }
        return fi;
    }

    /***********************
     * Create a deep copy of `this`
     * Returns:
     *  a copy
     */
    CtorFlow clone()
    {
        return CtorFlow(callSuper, saveFieldInit());
    }

    /**********************************
     * Set CSX bits in flow analysis state
     * Params:
     *  csx = bits to set
     */
    void orCSX(CSX csx) nothrow pure
    {
        callSuper |= csx;
        foreach (ref u; fieldinit)
            u |= csx;
    }

    /******************************
     * OR CSX bits to `this`
     * Params:
     *  ctorflow = bits to OR in
     */
    void OR(const ref CtorFlow ctorflow) pure nothrow
    {
        callSuper |= ctorflow.callSuper;
        if (fieldinit.length && ctorflow.fieldinit.length)
        {
            assert(fieldinit.length == ctorflow.fieldinit.length);
            foreach (i, u; ctorflow.fieldinit)
                fieldinit[i] |= u;
        }
    }
}


/****************************************
 * Merge `b` flow analysis results into `a`.
 * Params:
 *      a = the path to merge `b` into
 *      b = the other path
 * Returns:
 *      false means one of the paths skips construction
 */
bool mergeCallSuper(ref CSX a, const CSX b) pure nothrow
{
    // This does a primitive flow analysis to support the restrictions
    // regarding when and how constructors can appear.
    // It merges the results of two paths.
    // The two paths are `a` and `b`; the result is merged into `a`.
    if (b == a)
        return true;

    // Have ALL branches called a constructor?
    const aAll = (a & (CSX.this_ctor | CSX.super_ctor)) != 0;
    const bAll = (b & (CSX.this_ctor | CSX.super_ctor)) != 0;
    // Have ANY branches called a constructor?
    const aAny = (a & CSX.any_ctor) != 0;
    const bAny = (b & CSX.any_ctor) != 0;
    // Have any branches returned?
    const aRet = (a & CSX.return_) != 0;
    const bRet = (b & CSX.return_) != 0;
    // Have any branches halted?
    const aHalt = (a & CSX.halt) != 0;
    const bHalt = (b & CSX.halt) != 0;
    if (aHalt && bHalt)
    {
        a = CSX.halt;
    }
    else if ((!bHalt && bRet && !bAny && aAny) || (!aHalt && aRet && !aAny && bAny))
    {
        // If one has returned without a constructor call, there must not
        // be ctor calls in the other.
        return false;
    }
    else if (bHalt || bRet && bAll)
    {
        // If one branch has called a ctor and then exited, anything the
        // other branch has done is OK (except returning without a
        // ctor call, but we already checked that).
        a |= b & (CSX.any_ctor | CSX.label);
    }
    else if (aHalt || aRet && aAll)
    {
        a = cast(CSX)(b | (a & (CSX.any_ctor | CSX.label)));
    }
    else if (aAll != bAll) // both branches must have called ctors, or both not
        return false;
    else
    {
        // If one returned without a ctor, remember that
        if (bRet && !bAny)
            a |= CSX.return_;
        a |= b & (CSX.any_ctor | CSX.label);
    }
    return true;
}


/****************************************
 * Merge `b` flow analysis results into `a`.
 * Params:
 *      a = the path to merge `b` into
 *      b = the other path
 * Returns:
 *      false means either `a` or `b` skips initialization
 */
bool mergeFieldInit(ref CSX a, const CSX b) pure nothrow
{
    if (b == a)
        return true;

    // Have any branches returned?
    const aRet = (a & CSX.return_) != 0;
    const bRet = (b & CSX.return_) != 0;
    // Have any branches halted?
    const aHalt = (a & CSX.halt) != 0;
    const bHalt = (b & CSX.halt) != 0;

    if (aHalt && bHalt)
    {
        a = CSX.halt;
        return true;
    }

    bool ok;
    if (!bHalt && bRet)
    {
        ok = (b & CSX.this_ctor);
        a = a;
    }
    else if (!aHalt && aRet)
    {
        ok = (a & CSX.this_ctor);
        a = b;
    }
    else if (bHalt)
    {
        ok = (a & CSX.this_ctor);
        a = a;
    }
    else if (aHalt)
    {
        ok = (b & CSX.this_ctor);
        a = b;
    }
    else
    {
        ok = !((a ^ b) & CSX.this_ctor);
        a |= b;
    }
    return ok;
}

