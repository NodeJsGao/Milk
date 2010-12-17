# Milk is a simple, fast way to get more Mustache into your CoffeeScript and
# Javascript.
#
# Plenty of good resources for Mustache can be found
# [here](mustache.github.com), so little will be said about the templating
# language itself here.
#
# Template rendering is broken into a couple of distinct phases: deconstructing
# a parse tree, and generating the final result.

#### Parsing

# Mustache templates are reasonably simple -- plain text templates are
# sprinkled with "tags", which are (by default) a pair of curly braces
# surrounding some bit of content.
[tagOpen, tagClose] = ['{{', '}}']

# We're going to take the easy route this time, and just match away large parts
# of the template with a regular expression.  This isn't likely the fastest
# approach, but it is fairly simple.
# Since the tag delimiters can change over time, we'll need to rebuild the
# regex when they change.
BuildRegex = ->
  return ///
    ((?:.|\n)*?)               # Capture the pre-tag content
    ([#{' '}\t]*)              # Capture the pre-tag whitespace
    (?:#{tagOpen} \s*)         # Match the opening tag
    (?:
      (=)   \s* (.+?) \s* = |  # Capture type and content for Set Delimiters
      ({)   \s* (.+?) \s* } |  # Capture type and content for Triple Mustaches
      (\W?) \s* ((?:.|\n)+?)   # Capture type and content for everything else
    )
    (?:\s* #{tagClose})        # Match the closing tag
  ///gm

# In the simplest case, we'll simply need a template string to parse.  If we've
# parsed this template before, the cache will let us bail early.
TemplateCache = {}

Parse = (template, sectionName = null, templateStart = 0) ->
  return TemplateCache[template] if template of TemplateCache

  buffer = []
  tagPattern = BuildRegex()
  tagPattern.lastIndex = pos = templateStart

  # As we start matching things, we'll pull out the relevant captures, indices,
  # and deterimine whether the tag is standalone.
  while match = tagPattern.exec(template)
    [content, whitespace] = match[1..2]
    type = match[3] || match[5] || match[7]
    tag  = match[4] || match[6] || match[8]

    contentEnd = (pos + content.length) - 1
    pos        = tagPattern.lastIndex

    isStandalone = template[contentEnd] in [ undefined, '\n' ] and
                   template[pos]        in [ undefined, '\n' ]

    # Append the static content to the buffer.
    buffer.push content

    # If we're dealing with a standalone non-interpolation tag, we should skip
    # over the newline immediately following the tag.  If we're not, we need
    # give back the whitespace we've been holding hostage.
    if isStandalone and type not in ['', '&', '{']
      pos += 1
    else if whitespace
      buffer.push(whitespace)
      whitespace = ''

    # Next, we'll handle the tag itself:
    switch type

      # Comment tags should simply be ignored.
      when '!' then break

      # Interpolation tags only require the tag name.
      when '', '&', '{' then buffer.push [ type, tag ]

      # Partial will require the tag name and any leading whitespace, which
      # will be used to indent the partial.
      when '>' then buffer.push [ type, tag, whitespace ]

      # Sections and Inverted Sections make a recursive call to `Parse`,
      # starting immediately after the tag.  This call will continue to walk
      # through the template until it reaches an End Section tag, when it will
      # return the subtemplate it's parsed (and cached!) and the index after
      # the End Section tag.  We'll save the tag name and subtemplate string.
      when '#', '^'
        [tmpl, pos] = Parse(template, tag, pos)
        buffer.push [ type, tag, tmpl ]

      when '/'
        template = template[templateStart..contentEnd]
        TemplateCache[template] = buffer
        return [template, pos]

      # The Set Delimeters tag doesn't actually generate output, but instead
      # changes the tagPattern that the parser uses.  All delimeters need to be
      # regex escaped for safety.
      when '='
        [tagOpen, tagClose] = for delim in tag.split(/\s+/)
          delim.replace(/[-[\]{}()*+?.,\\^$|#]/g, "\\$&")
        tagPattern = BuildRegex()

      else throw "Unknown tag type -- #{type}"

    # And finally, we'll advance the tagPattern's lastIndex (so that it resumes
    # parsing where we intend it to), and loop.
    tagPattern.lastIndex = pos

  # When we've exhausted all of the matches for tagPattern, we'll still have a
  # small portion of the template remaining.  We'll append it to the buffer,
  # cache it, and return the buffer!
  buffer.push(template[pos..])
  return TemplateCache[template] = buffer

#### Generating

# Once we have a parse tree, transforming it back into a full template should
# be fairly straightforward.  We start by building a context stack, which data
# will be looked up from.
Generate = (buffer, data, partials = {}, context = []) ->
  context.push data if data and data.constructor is Object

  Build = (tmpl, data) -> Generate(Parse(tmpl), data, partials, [context...])

  parts = for part in buffer
    switch typeof part

      # Strings in the buffer can be used literally.
      when 'string' then part

      # Parsed tags (which will be Arrays in the given buffer) will need to be
      # evaluated against the context stack.
      else
        [type, name, data] = part
        value = Find(name, context) unless type is '>'

        switch type

          # Partials will be looked up by name (in this case, from the given
          # hash) and built.  (Parsing the partial here means that we don't
          # have to worry about recursive partials.)  If the partial tag was
          # standalone and indented, the resulting content should be similarly
          # indented.
          when '>'
            content = Build(partials[name] || '')
            content = content.replace(/^(?=.)/gm, data) if data
            content

          # Sections will render when the name specified retreives a truthy
          # value from the context stack, and should be repeated for each
          # element if the value is an array.  If the value is a function, it
          # should be called with the raw section template, and the return
          # value should be built.
          when '#'
            switch (value ||= []).constructor
              when Array    then (Build(data, v) for v in value).join('')
              when Function then Build(value(data))
              else               Build(data, value)

          # Inverted Sections render under almost opposite conditions: their
          # contents will only be rendered whene the retrieved value is falsey,
          # or is an empty array.
          when '^'
            empty = (value ||= []) instanceof Array and value.length is 0
            if empty then Build(data) else ''

          # Unescaped interpolations should be returned directly; Escaped
          # interpolations will need to be HTML escaped for safety.
          # For lambdas that we receive, we'll simply call them and compile
          # whatever they return.
          when '&', '{' 
            value = Build(value()) if value instanceof Function
            value.toString()
          when ''
            value = Build(value()) if value instanceof Function
            Escape(value.toString())

  # The generated result is the concatenation of all these parts.
  return parts.join('')

#### Helpers

# `Find` will walk the context stack from top to bottom, looking for an element
# with the given name.
Find = (name, stack) ->
  value = ''
  for i in [stack.length - 1...-1]
    continue unless name of (ctx = stack[i])
    value = ctx[name]
    break

  # If the value is a function, it will be treated like an object method; we'll
  # call it, and use its return value as the new value.
  # If the result is also a function, we'll treat that as an unbound lambda.
  # Lambdas get called and cached when used in interpolations, and receive the
  # raw section content when used in a Section tag.  Both are subsequently
  # expanded in the current context.
  value = value.apply(ctx) if value instanceof Function

  if (func = value) instanceof Function
    value = ->
      result = func.apply(this, arguments).toString()
      ctx[name] = result if arguments.length is 0
      return result

  # Null values will be coerced to the empty string.
  return value ? ''

# `Escape` lets us quickly replace HTML-reserved characters with their entity
# equivalents.
Escape = (value) ->
  entities = { '&': 'amp', '"': 'quot', '<': 'lt', '>': 'gt' }
  return value.replace(/[&"<>]/g, (char) -> "&#{ entities[char] };")

#### Exports

# In CommonJS-based environments, Milk will export a single function, `render`.
# In browsers, and other non-CommonJS environments, the object `Milk` will be
# exported to the global namespace, containing the same `render` method.
#
# All environments presently support only synchronous rendering of in-memory
# templates, partials, and data.
#
# Happy hacking!
Milk =
  render: (template, data, partials = {}) ->
    [tagOpen, tagClose] = ['{{', '}}']
    return Generate(Parse(template), data, partials)

if exports?
  exports[key] = Milk[key] for key of Milk
else
  this.Milk = Milk
