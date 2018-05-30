export @const_gate

abstract type ConstantGate{N, T} <: PrimitiveBlock{N, T} end

# TODO: better exception for X::Complex64 without import XGate

"""
    @const_gate

A macro to define new constant gate. It will automatically bind your assigned matrix to an constant, which
will reduce the memory allocation. You can also use it to bind new type of matrix, or re-define this const
gate.

## Example

this defines X gate and bind a constant of type `Complex128` to method `mat`, which will be called
during your calculation of X gate. You should input the matrix type you want to use in your calculation,
we will only help you do its element type conversion.

```julia
# dense matrix
julia> @const_gate X = ComplexF64[0 1;1 0]
# sparse matrix
julia> @const_gate X = sparse(ComplexF64[0 1;1 0])
```

You can also let this macro to handle the type, just declare with the type annotation. It will do the conversion
and bind a `ComplexF64` constant to `mat` itself. No worries!

```julia
julia> @const_gate X::ComplexF64 = [0 1;1 0]
```

if you have already declared this gate, but you want to let its `mat` method bind some other type. Simply write

```julia
julia> @const_gate X::ComplexF32
```

then the macro will try to find your previous binding and create a new constant which will be binded to method
`mat`.
"""
macro const_gate(ex)
    if @capture(ex, NAME_::TYPE_ = EXPR_)
        define_typed_const_gate(NAME, TYPE, EXPR)
    elseif @capture(ex, NAME_ = EXPR_)
        define_const_gate(NAME, EXPR)
    elseif @capture(ex, NAME_::TYPE_)
        define_const_gate_new_type(NAME, TYPE)
    else
        throw(MethodError(Symbol("@const_gate"), ex))
    end
end

const_gate_typename(name) = Symbol(join([name, "Gate"]))

"""
    define_const_gate_struct(n, name)

define a immutable concrete type the constant gate. `n` is the number of qubits.
`name` is the desired type name it will also be used as tag name, etc. It returns
false if this constant gate is already defined (or this name is already
used in current scope). or it returns true.
"""
function define_const_gate_struct(n, name)
    # NOTE: isdefined requires a symbol
    # do not input an escaped symbol
    if isdefined(name)
        return :(false)
    end

    typename = const_gate_typename(name)
    quote
        struct $(esc(typename)){T} <: Yao.ConstantGate{$n, T}
        end

        const $(esc(name)) = $(esc(typename)){$CircuitDefaultType}()
        # printing infos
        $(define_const_gate_printing(name))
        true
    end
end

"""
    define_const_gate_property(f, property, gate, mat_ex) -> ex

define `property` calculated by an expression generated by function `f` with `mat_ex`
for `gate`.
"""
function define_const_gate_property(f, property, name, cname)
    method_name = Symbol(join(["is", property]))
    flag_name = Symbol(join(["flag", property], "_"))
    typename = const_gate_typename(name)

    method_name = :(Yao.$method_name)
    quote
        const $flag_name = $(f(cname))
        $(esc(method_name))(::Type{GT}) where {GT <: $(esc(typename))} = $flag_name
        $(esc(method_name))(::GT) where {GT <: $(esc(typename))} = $flag_name
    end
end

function define_const_gate_properties(name, cname)
    quote
        $(define_const_gate_property(x->:($x * $x ≈ speye(size($x, 1))), :reflexive, name, cname))
        $(define_const_gate_property(x->:($x' ≈ $x), :hermitian, name, cname))
        $(define_const_gate_property(x->:($x * $x' ≈ speye(size($x, 1))), :unitary, name, cname))
    end
end

function define_const_gate_mat_fallback(name, t)
    typename = const_gate_typename(name)
    quote
        function $(esc(:(Yao.mat)))(::Type{$(esc(typename)){T}}) where {T <: Complex}
            src = mat($(esc(typename)){$t})
            dest = similar(src, T)
            copy!(dest, src)
            dest
        end
    end
end

function define_const_gate_printing(name)
    typename = const_gate_typename(name)
    msg = string(name)
    quote
        function $(esc(:(Base.show)))(io::IO, ::$(esc(typename)))
            print(io, $(msg), " gate")
        end
    end
end

function define_const_gate_methods(name, t, cname)
    typename = const_gate_typename(name)
    quote
        # callable
        # use instance for factory methods
        (::$(esc(typename)))() = $(esc(typename)){$CircuitDefaultType}()
        (::$(esc(typename)))(::Type{T}) where {T <: Complex} = $(esc(typename)){T}()

        # forward to apply! if the first arg is a register
        (gate::$(esc(typename)))(r::AbstractRegister, params...) = apply!(r, gate, params...)

        # define shortcuts
        (gate::$(esc(typename)))(itr) = RangedBlock(gate, itr)
        # TODO: use Repeated instead
        (gate::$(esc(typename)))(n::Int, pos) = KronBlock{n}(i=>$(esc(name)) for i in pos)

        # define fallback methods for mat
        ## dispatch to default type
        $(esc(:(Yao.mat)))(::Type{$(esc(typename))}) = $(esc(:mat))($(esc(typename)){$CircuitDefaultType})
        $(esc(:(Yao.mat)))(gate::GT) where {GT <: $(esc(typename))} = $(esc(:mat))(GT)
        $(define_const_gate_mat_fallback(name, t))

        # define properties
        $(define_const_gate_properties(name, cname))
    end
end

"""
    define_typed_const_gate(name, type, ex)

like `define_const_gate`, but this binds `ex` to a type specific by
the user.
"""
function define_typed_const_gate(name, t, ex)
    n = :N
    CONST_NAME = Symbol(join([name, "CONST"], "_"))
    typename = const_gate_typename(name)

    quote
        const $CONST_NAME = similar($(esc(ex)), $t)
        copy!($CONST_NAME, $(esc(ex)))

        $n = log2i(size($CONST_NAME, 1))
        issuccessed = $(define_const_gate_struct(n, name))

        $(esc(:(Yao.mat)))(::Type{$(esc(typename)){$t}}) = $CONST_NAME

        # only define this for the first time
        if issuccessed
            $(define_const_gate_methods(name, t, CONST_NAME))
        end
    end
end

"""
    define_const_gate_new_type(name, type)

define new constant matrix binding with `type` for this const gate. it throws
`UndefVarError` if this constant gate is not defined.
"""
function define_const_gate_new_type(name, t)
    CONST_NAME = Symbol(join([name, "CONST"], "_"))
    typename = const_gate_typename(name)
    quote
        if $(!isdefined(name))
            throw($(UndefVarError(name)))
        end

        const $CONST_NAME = mat($(esc(typename)){$t})
        $(esc(:(Yao.mat)))(::Type{$(esc(typename)){$t}}) = $CONST_NAME
    end
end

"""
    define_const_gate(name, ex)

define type, peroperties, matrix, etc. for this constant gate.
"""
function define_const_gate(name, ex)
    n = :N
    CONST_NAME = Symbol(join([name, "CONST"], "_"))
    elt = :FallbackType
    typename = const_gate_typename(name)

    quote
        const $CONST_NAME = $(esc(ex))
        $n = log2i(size($CONST_NAME, 1))
        issuccessed = $(define_const_gate_struct(n, name))

        if !issuccessed
            warn($(esc(name)), " is already defined, check if your desired name is available.")
        end

        $elt = eltype($CONST_NAME)
        if !($elt <: Complex)
            warn($(esc(name)), " only accept complex typed matrix, your constant matrix has eltype: ", $elt)
        end
        $(esc(:(Yao.mat)))(::Type{$(esc(typename)){$elt}}) = $CONST_NAME

        # only define this for the first time
        if issuccessed
            $(define_const_gate_methods(name, elt, CONST_NAME))
        end
    end
end


for (NAME, _) in Const.SYM_LIST
    GT = Symbol(join([NAME, "Gate"]))
    @eval begin
        export $NAME, $GT
        @const_gate $NAME = Const.Sparse.$NAME($CircuitDefaultType)
    end
end